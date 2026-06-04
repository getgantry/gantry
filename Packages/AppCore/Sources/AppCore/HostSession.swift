import Foundation
import Observation
import DockerKit
import SSHKit

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

    // MARK: - SSH interactive prompts

    /// A request for a secret (SSH password or key passphrase) that the UI must
    /// satisfy before the in-flight connection can proceed.
    public struct CredentialRequest: Identifiable, Sendable {
        public enum Kind: Sendable, Equatable {
            case password
            case keyPassphrase(file: String)
        }

        public let id = UUID()
        public let kind: Kind
        public let hostName: String
    }

    /// First-time host key prompt (trust-on-first-use). Presented when the
    /// remote presents an unknown host key.
    public struct HostKeyPromptState: Identifiable, Sendable {
        public let id = UUID()
        public let host: String
        public let fingerprint: String
        public let keyType: String
    }

    /// Set while `connect()` is waiting for the UI to supply a secret.
    public private(set) var pendingCredentialRequest: CredentialRequest?

    /// Set while `connect()` is waiting for a trust-on-first-use decision.
    public private(set) var pendingHostKeyPrompt: HostKeyPromptState?

    /// Continuation resumed once the UI answers a credential request. Carries
    /// the secret plus whether to persist it to the Keychain, or nil on cancel.
    private var credentialContinuation: CheckedContinuation<(secret: String, store: Bool)?, Never>?

    /// Continuation resumed once the UI answers a host-key prompt.
    private var hostKeyContinuation: CheckedContinuation<Bool, Never>?

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
            await finishConnect(with: transport)

        case .ssh(let endpoint):
            await connectSSH(endpoint)
        }
    }

    /// Negotiates and brings the session up over an already-built transport.
    /// Shared by the local and SSH paths so status transitions stay identical.
    private func finishConnect(with transport: DockerTransport) async {
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
            // DockerClient.shutdown forwards to the transport; nothing more to release.
            status = .failed(error.localizedDescription)
        }
    }

    // MARK: - SSH connection

    private func connectSSH(_ endpoint: SSHEndpoint) async {
        // Resolve ssh_config to fill any gaps the user left blank.
        let resolved = SSHConfig.resolve(host: endpoint.host)

        let hostName = endpoint.host.isEmpty ? resolved.hostName : endpoint.host
        let port = endpoint.port != 0 ? endpoint.port : resolved.port
        let username: String = {
            if !endpoint.username.isEmpty { return endpoint.username }
            if let user = resolved.user, !user.isEmpty { return user }
            return NSUserName()
        }()

        // Build the host-key policy: known hosts pass; unknown hosts prompt the
        // user (trust-on-first-use) by hopping back to the main actor.
        let knownHosts = KnownHostsStore()
        let policy = HostKeyPolicy.acceptKnown(knownHosts) { [weak self] candidate in
            await self?.promptHostKey(host: hostName, candidate: candidate) ?? .reject
        }

        // Resolve auth, possibly suspending for a Keychain miss / user prompt.
        let auth: AuthSource
        do {
            auth = try await resolveAuth(
                endpoint: endpoint,
                hostName: hostName,
                resolvedIdentityFiles: resolved.identityFiles
            )
        } catch is CancellationError {
            status = .failed("Connection cancelled")
            return
        } catch {
            status = .failed(error.localizedDescription)
            return
        }

        let parameters = SSHConnectionParameters(
            host: hostName,
            port: port,
            username: username,
            auth: auth
        )

        let transport = SSHDialStdioTransport {
            try await SSHConnector.connect(parameters: parameters, policy: policy)
        }

        await finishConnect(with: transport)
    }

    /// Determines the authentication method, consulting the Keychain and, when
    /// necessary, prompting the user for a secret. Throws `CancellationError`
    /// if the user cancels.
    private func resolveAuth(
        endpoint: SSHEndpoint,
        hostName: String,
        resolvedIdentityFiles: [String]
    ) async throws -> AuthSource {
        switch endpoint.auth {
        case .automatic:
            let candidates = resolvedIdentityFiles + SSHKeyLoader.defaultKeyCandidates()
            return try await loadFirstUsableKey(from: candidates, hostName: hostName)

        case .keyFile(let path):
            return try await loadFirstUsableKey(from: [path], hostName: hostName)

        case .password:
            let account = KeychainStore.sshPasswordAccount(hostID: host.id)
            if let stored = KeychainStore.get(account: account) {
                return .password(stored)
            }
            let answer = try await requestCredential(.init(kind: .password, hostName: hostName))
            if answer.store {
                KeychainStore.set(answer.secret, account: account)
            }
            return .password(answer.secret)
        }
    }

    /// Tries each candidate key path in order, returning the first that loads.
    /// Passphrase-protected keys are unlocked via the Keychain or a user prompt.
    private func loadFirstUsableKey(
        from paths: [String],
        hostName: String
    ) async throws -> AuthSource {
        let passphraseAccount = KeychainStore.keyPassphraseAccount(hostID: host.id)
        var lastError: Error?

        for path in paths {
            do {
                let key = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
                return .key(key)
            } catch SSHKeyError.needsPassphrase {
                // Try a stored passphrase first.
                if let stored = KeychainStore.get(account: passphraseAccount) {
                    if let key = try? SSHKeyLoader.load(contentsOf: path, passphrase: stored) {
                        return .key(key)
                    }
                }
                // Ask the user.
                let answer = try await requestCredential(
                    .init(kind: .keyPassphrase(file: path), hostName: hostName)
                )
                do {
                    let key = try SSHKeyLoader.load(contentsOf: path, passphrase: answer.secret)
                    if answer.store {
                        KeychainStore.set(answer.secret, account: passphraseAccount)
                    }
                    return .key(key)
                } catch {
                    lastError = error
                    continue
                }
            } catch {
                // Unloadable / missing file: try the next candidate.
                lastError = error
                continue
            }
        }

        throw lastError ?? DockerError.connectionFailed("No usable SSH key found")
    }

    // MARK: - Interactive prompt plumbing

    /// Publishes a credential request and suspends until the UI answers.
    /// Cancellation-safe: a cancelled task resumes the continuation with nil
    /// and surfaces as `CancellationError`.
    private func requestCredential(_ request: CredentialRequest) async throws -> (secret: String, store: Bool) {
        let answer = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(secret: String, store: Bool)?, Never>) in
                self.credentialContinuation = continuation
                self.pendingCredentialRequest = request
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelCredential()
            }
        }

        guard let answer else { throw CancellationError() }
        return answer
    }

    /// UI entry point: supply the requested secret, optionally storing it.
    public func submitCredential(_ secret: String, store: Bool) {
        pendingCredentialRequest = nil
        let continuation = credentialContinuation
        credentialContinuation = nil
        continuation?.resume(returning: (secret: secret, store: store))
    }

    /// UI entry point: abandon the credential request.
    public func cancelCredential() {
        pendingCredentialRequest = nil
        let continuation = credentialContinuation
        credentialContinuation = nil
        continuation?.resume(returning: nil)
    }

    /// Publishes a host-key prompt and suspends until the user decides.
    private func promptHostKey(host: String, candidate: HostKeyCandidate) async -> HostKeyDecision {
        let trusted = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            self.hostKeyContinuation = continuation
            self.pendingHostKeyPrompt = HostKeyPromptState(
                host: host,
                fingerprint: candidate.fingerprintSHA256,
                keyType: candidate.keyType
            )
        }
        return trusted ? .trust : .reject
    }

    /// UI entry point: accept or reject the pending host key.
    public func submitHostKeyDecision(trust: Bool) {
        pendingHostKeyPrompt = nil
        let continuation = hostKeyContinuation
        hostKeyContinuation = nil
        continuation?.resume(returning: trust)
    }

    public func disconnect() async {
        eventTask?.cancel()
        eventTask = nil
        pendingContainerRefresh?.cancel()
        pendingContainerRefresh = nil
        liveUpdatesActive = false
        // Resolve any prompt left hanging by an interrupted connect attempt.
        cancelCredential()
        if pendingHostKeyPrompt != nil { submitHostKeyDecision(trust: false) }
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
