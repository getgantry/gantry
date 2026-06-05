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

    /// Routes an error into the user-facing alert, swallowing cancellations:
    /// a SwiftUI task cancelled by navigation is not a failure.
    private func surface(_ error: Error) {
        if error is CancellationError { return }
        if let docker = error as? DockerError, case .cancelled = docker { return }
        lastError = error.localizedDescription
    }

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

    /// Previous one-shot CPU counters per container, for the inter-tick
    /// deltas behind `containerLoad()`.
    private var loadCPUBaseline: [String: (total: Int64, system: Int64)] = [:]

    /// Rolling container-load history (~10 minutes at one sample every 5 s),
    /// collected for the whole lifetime of the connection so dashboards have
    /// data the moment they appear instead of starting from scratch.
    public private(set) var loadHistory: [LoadSample] = []

    /// Background sampler feeding `loadHistory`; runs while connected.
    private var loadSamplingTask: Task<Void, Never>?

    private static let loadHistoryWindow = 120

    /// Factory for additional SSH connections to this host (host shell, SFTP
    /// file browsing). Set while an SSH host is connected; nil for local.
    private var sshClientFactory: (@Sendable () async throws -> SSHClient)?

    /// Lazy SFTP browser for the host filesystem; one per session.
    private var hostFileSystemStorage: SSHHostFileSystem?

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
            startLoadSampling()
        } catch {
            await client.shutdown()
            self.client = nil
            // DockerClient.shutdown forwards to the transport; nothing more to release.
            status = .failed(error.localizedDescription)
        }
    }

    /// TEST SEAM: injects an already-negotiated `DockerClient` and marks the
    /// session connected, bypassing the real socket/SSH dial. This exists only
    /// so the test suite can drive `refresh*`, `perform`, `mutate*`, prune/remove/
    /// create, inspection and stats paths against a `MockTransport`-backed client
    /// without a live daemon. Not used by the app at runtime.
    func _setConnectedClientForTesting(_ client: DockerClient, version: SystemVersion) {
        self.client = client
        status = .connected(version)
    }

    // MARK: - SSH connection

    private func connectSSH(_ endpoint: SSHEndpoint) async {
        // Resolve ssh_config to fill any gaps the user left blank (shared with
        // the headless paths so the GUI and MCP/Intents dial the same host).
        let resolved = ResolvedSSHEndpoint.resolve(endpoint)
        let hostName = resolved.hostName
        let port = resolved.port
        let username = resolved.username

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

        let makeClient: @Sendable () async throws -> SSHClient = {
            try await SSHConnector.connect(parameters: parameters, policy: policy)
        }
        let transport = SSHDialStdioTransport(makeClient: makeClient)

        await finishConnect(with: transport)
        if status.isConnected {
            sshClientFactory = makeClient
        }
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
        loadSamplingTask?.cancel()
        loadSamplingTask = nil
        loadHistory = []
        loadCPUBaseline = [:]
        pendingContainerRefresh?.cancel()
        pendingContainerRefresh = nil
        sshClientFactory = nil
        if let fs = hostFileSystemStorage {
            hostFileSystemStorage = nil
            Task { await fs.close() }
        }
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
            // Clear the marker before the refresh so an event arriving while
            // the reload is in flight schedules another one (no lost update).
            self?.pendingContainerRefresh = nil
            await self?.refreshContainers()
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
        await refresh(\.containers) { try await $0.listContainers(all: true) }
    }

    public func refreshImages() async {
        await refresh(\.images) { try await $0.listImages() }
    }

    public func refreshVolumes() async {
        await refresh(\.volumes) { try await $0.listVolumes() }
    }

    public func refreshNetworks() async {
        await refresh(\.networks) { try await $0.listNetworks() }
    }

    /// Reloads one resource list, storing the result on success.
    private func refresh<T>(
        _ keyPath: ReferenceWritableKeyPath<HostSession, [T]>,
        _ body: (DockerClient) async throws -> [T]
    ) async {
        guard let client else { return }
        if let value = await fetch({ try await body(client) }) {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: - Container actions

    public func perform(_ action: ContainerAction, on id: String) async -> Bool {
        await mutate(refresh: refreshContainers) { client in
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
            surface(error)
            return nil
        }
    }

    // MARK: - Log / stats streams

    /// Opens a follow log stream for a container. Inspects the container first
    /// to learn whether it allocated a TTY (which changes the wire framing),
    /// then tails the last 100 lines and follows new output.
    public func logStream(for containerID: String) async throws -> AsyncThrowingStream<LogEntry, Error> {
        guard let client else {
            throw DockerError.connectionFailed("Not connected")
        }
        let details = try await client.inspectContainer(id: containerID)
        return try await client.containerLogs(
            id: containerID,
            tty: details.config.tty,
            follow: true,
            tail: 100,
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
            surface(error)
            return nil
        }
    }

    /// Runs a mutation against the client; on success runs `refresh` and
    /// returns true. Failures are recorded in `lastError`.
    private func mutate(
        refresh: () async -> Void = {},
        _ body: (DockerClient) async throws -> Void
    ) async -> Bool {
        guard let client else {
            lastError = "Not connected"
            return false
        }
        do {
            try await body(client)
            await refresh()
            return true
        } catch {
            surface(error)
            return false
        }
    }

    /// Like `mutate`, but for calls that produce a value: returns it on
    /// success (after running `refresh`), or nil with `lastError` set.
    private func mutateValue<T>(
        refresh: () async -> Void = {},
        _ body: (DockerClient) async throws -> T
    ) async -> T? {
        guard let client else {
            lastError = "Not connected"
            return nil
        }
        do {
            let value = try await body(client)
            await refresh()
            return value
        } catch {
            surface(error)
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
    /// `internal` (not `private`) only so the test suite can exercise the
    /// formatting/fallback branches directly.
    static func prettyJSON(from data: Data) -> String {
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

// MARK: - Host shell & host filesystem (SSH hosts)

extension HostSession {
    /// True when this host can open a host shell / browse the host
    /// filesystem — i.e. it is a connected SSH host.
    public var supportsHostAccess: Bool {
        sshClientFactory != nil && status.isConnected
    }

    /// Opens an interactive PTY shell on the SSH host over a dedicated
    /// connection (independent of the Docker tunnel).
    public func openHostShell() throws -> HostShellSession {
        guard let factory = sshClientFactory else {
            throw DockerError.connectionFailed("A host shell requires a connected SSH host")
        }
        return HostShellSession(shell: SSHHostShell(makeClient: factory))
    }

    /// The SFTP browser for the host filesystem, created on first use and
    /// torn down on disconnect.
    public func hostFileSystem() throws -> SSHHostFileSystem {
        guard let factory = sshClientFactory else {
            throw DockerError.connectionFailed("Host file browsing requires a connected SSH host")
        }
        if let existing = hostFileSystemStorage { return existing }
        let fs = SSHHostFileSystem(makeClient: factory)
        hostFileSystemStorage = fs
        return fs
    }
}

// MARK: - Interactive exec

extension HostSession {
    /// Creates and starts a single-command interactive exec, returning a live
    /// `ExecSession` the UI drives. The command is run with a TTY. Shell
    /// fallback (e.g. try `bash` then `sh`) is the caller's concern: this method
    /// runs exactly one command and surfaces the failure if it cannot start.
    public func openExecSession(containerID: String, command: [String]) async throws -> ExecSession {
        guard let client else {
            throw DockerError.connectionFailed("Not connected")
        }
        let execID = try await client.createExec(containerID: containerID, command: command, tty: true)
        let connection = try await client.startExecHijacked(execID: execID, tty: true)
        return ExecSession(execID: execID, tty: true, connection: connection, client: client)
    }
}

// MARK: - Container management wrappers
//
// Thin pass-throughs over the DockerClient endpoints used by the container
// views. They follow the existing perform/refresh style: surface failures via
// `lastError` where a Bool/void result is enough, and rethrow where the view
// needs the value or wants inline error handling.

extension HostSession {
    /// Creates a container from `config` and immediately starts it, refreshing
    /// the list afterwards. Returns the new container ID, or throws so the
    /// caller can offer a "pull image and retry" path on a 404.
    @discardableResult
    public func createAndRun(_ config: ContainerCreateRequest) async throws -> String {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        let id = try await client.createContainer(config: config, name: config.name)
        try await client.startContainer(id: id)
        await refreshContainers()
        return id
    }

    /// Creates a container from `config` without starting it.
    @discardableResult
    public func createContainer(_ config: ContainerCreateRequest) async throws -> String {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        let id = try await client.createContainer(config: config, name: config.name)
        await refreshContainers()
        return id
    }

    /// Renames a container, refreshing the list. Returns false on failure.
    @discardableResult
    public func rename(containerID: String, to name: String) async -> Bool {
        await mutate(refresh: refreshContainers) {
            try await $0.renameContainer(id: containerID, to: name)
        }
    }

    /// Commits a container to a new image. Returns false on failure.
    @discardableResult
    public func commit(containerID: String, repo: String, tag: String, comment: String) async -> Bool {
        await mutate(refresh: refreshImages) {
            _ = try await $0.commitContainer(id: containerID, repo: repo, tag: tag, comment: comment)
        }
    }

    /// Updates a container's restart policy, refreshing the list afterwards.
    @discardableResult
    public func updateRestartPolicy(containerID: String, policy: String, maxRetries: Int) async -> Bool {
        await mutate(refresh: refreshContainers) {
            try await $0.updateRestartPolicy(id: containerID, policy: policy, maxRetries: maxRetries)
        }
    }

    /// Removes all stopped containers. Returns the prune result, or nil on
    /// failure (recorded in `lastError`).
    public func pruneStoppedContainers() async -> PruneResult? {
        await mutateValue(refresh: refreshContainers) { try await $0.pruneContainers() }
    }

    /// Opens the export byte stream for a container's filesystem (a tar).
    public func exportFilesystem(containerID: String) async throws -> DockerByteStream {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        return try await client.exportContainer(id: containerID)
    }

    // MARK: Processes

    /// Lists the running processes inside a container (`docker top`).
    public func processes(containerID: String) async throws -> ContainerTop {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        return try await client.containerProcesses(id: containerID)
    }

    // MARK: Files

    /// Lists a directory inside a container.
    ///
    /// Prefers the shell-based fast path (`listDirectoryFast`), which transfers
    /// only the listing text. If the container has no usable shell (distroless /
    /// scratch) the fast path throws `ExecListError` and we fall back to the
    /// archive-based `listDirectory`, which tars the subtree (bounded at 64 MB).
    public func listDirectory(containerID: String, path: String) async throws -> [ContainerFileEntry] {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        do {
            return try await client.listDirectoryFast(containerID: containerID, path: path)
        } catch is ExecListError {
            // No shell / command failed — fall back to the archive listing.
            return try await client.listDirectory(containerID: containerID, path: path)
        }
    }

    /// Downloads a path from a container as a tar byte stream.
    public func downloadArchive(containerID: String, path: String) async throws -> DockerByteStream {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        return try await client.downloadArchive(containerID: containerID, path: path)
    }

    /// Uploads a tar archive into a container at `path`.
    public func uploadArchive(containerID: String, path: String, tar: Data) async throws {
        guard let client else { throw DockerError.connectionFailed("Not connected") }
        try await client.uploadArchive(containerID: containerID, path: path, tar: tar)
    }
}

// MARK: - Resource operations (M7)
//
// Wrappers for the image / volume / network / system resource views. Same
// style as the rest of the file: void/Bool/optional results record failures in
// `lastError`; streaming + value-returning calls rethrow so the view can drive
// inline feedback. Each mutation refreshes the affected list on success.

extension HostSession {
    // MARK: Images

    /// Pulls an image, returning the daemon's live per-layer progress stream.
    /// Pull errors surface as a thrown `DockerError` from the stream itself.
    /// Callers should `refreshImages()` once the stream finishes.
    public func pullImage(
        reference: String,
        auth: RegistryAuth? = nil
    ) async throws -> AsyncThrowingStream<PullProgress, Error> {
        guard let client else {
            throw DockerError.connectionFailed("Not connected")
        }
        return try await client.pullImage(reference: reference, auth: auth)
    }

    /// Returns the layer history for an image (newest first), or nil on failure.
    public func imageHistory(id: String) async -> [ImageHistoryEntry]? {
        await mutateValue { try await $0.imageHistory(id: id) }
    }

    /// Adds a `repo:tag` to an existing image. Refreshes images on success.
    @discardableResult
    public func tagImage(id: String, repo: String, tag: String) async -> Bool {
        await mutate(refresh: refreshImages) {
            try await $0.tagImage(id: id, repo: repo, tag: tag)
        }
    }

    /// Removes an image. Refreshes images on success.
    @discardableResult
    public func removeImage(id: String, force: Bool = false) async -> Bool {
        await mutate(refresh: refreshImages) {
            try await $0.removeImage(id: id, force: force)
        }
    }

    /// Prunes images. When `dangling` is true only untagged layers are removed;
    /// otherwise all unused images are pruned. Refreshes images on success.
    public func pruneImages(dangling: Bool) async -> PruneResult? {
        await mutateValue(refresh: refreshImages) { try await $0.pruneImages(dangling: dangling) }
    }

    // MARK: Volumes

    /// Creates a volume and refreshes the list on success.
    @discardableResult
    public func createVolume(
        name: String,
        driver: String = "local",
        labels: [String: String] = [:]
    ) async -> Volume? {
        await mutateValue(refresh: refreshVolumes) {
            try await $0.createVolume(name: name, driver: driver, labels: labels)
        }
    }

    /// Removes a volume. Refreshes the list on success.
    @discardableResult
    public func removeVolume(name: String, force: Bool = false) async -> Bool {
        await mutate(refresh: refreshVolumes) {
            try await $0.removeVolume(name: name, force: force)
        }
    }

    /// Prunes unused volumes. Refreshes the list on success.
    public func pruneVolumes() async -> PruneResult? {
        await mutateValue(refresh: refreshVolumes) { try await $0.pruneVolumes() }
    }

    // MARK: Networks

    /// Creates a network and refreshes the list on success. Returns the new id.
    @discardableResult
    public func createNetwork(
        name: String,
        driver: String = "bridge",
        labels: [String: String] = [:]
    ) async -> String? {
        await mutateValue(refresh: refreshNetworks) {
            try await $0.createNetwork(name: name, driver: driver, labels: labels)
        }
    }

    /// Removes a network. Refreshes the list on success.
    @discardableResult
    public func removeNetwork(id: String) async -> Bool {
        await mutate(refresh: refreshNetworks) {
            try await $0.removeNetwork(id: id)
        }
    }

    /// Prunes unused networks. Refreshes the list on success.
    public func pruneNetworks() async -> PruneResult? {
        await mutateValue(refresh: refreshNetworks) { try await $0.pruneNetworks() }
    }

    /// Attaches a container to a network. Refreshes networks on success.
    @discardableResult
    public func connectContainer(networkID: String, containerID: String) async -> Bool {
        await mutate(refresh: refreshNetworks) {
            try await $0.connectContainer(networkID: networkID, containerID: containerID)
        }
    }

    /// Detaches a container from a network. Refreshes networks on success.
    @discardableResult
    public func disconnectContainer(
        networkID: String,
        containerID: String,
        force: Bool = false
    ) async -> Bool {
        await mutate(refresh: refreshNetworks) {
            try await $0.disconnectContainer(networkID: networkID, containerID: containerID, force: force)
        }
    }

    // MARK: System

    /// Returns aggregate disk usage across images, containers and volumes,
    /// or nil on failure (recorded in `lastError`).
    public func systemDF() async -> SystemDiskUsage? {
        await mutateValue { try await $0.systemDF() }
    }

    /// Live aggregate load across the host's running containers: total CPU
    /// percentage (100 = one core) and memory used.
    ///
    /// Uses immediate one-shot stats (cheap even over the serialized SSH
    /// tunnel) and derives each container's CPU from the counter delta
    /// against the previous call, the same way `docker stats` does between
    /// frames. The first call after connect reports CPU as 0 — the baseline
    /// is established then. Containers that vanish mid-sample are skipped.
    public func containerLoad() async -> ContainerLoad? {
        guard let client else { return nil }
        let running = containers.filter { $0.state.isRunning }.map(\.id)
        guard !running.isEmpty else {
            loadCPUBaseline = [:]
            return ContainerLoad(cpuPercent: 0, memoryUsedBytes: 0, sampled: 0)
        }

        let samples = await withTaskGroup(of: (String, ContainerStatsSample)?.self) { group in
            for id in running {
                group.addTask {
                    guard let sample = try? await client.containerStatsOnce(id: id) else { return nil }
                    return (id, sample)
                }
            }
            var collected: [(String, ContainerStatsSample)] = []
            for await pair in group {
                if let pair { collected.append(pair) }
            }
            return collected
        }

        var cpuPercent = 0.0
        var memoryUsed: Int64 = 0
        var baseline: [String: (total: Int64, system: Int64)] = [:]
        for (id, sample) in samples {
            memoryUsed += sample.memoryUsageBytes
            if let previous = loadCPUBaseline[id] {
                let cpuDelta = sample.cpuTotalUsage - previous.total
                let systemDelta = sample.systemCPUUsage - previous.system
                if cpuDelta > 0, systemDelta > 0 {
                    cpuPercent += Double(cpuDelta) / Double(systemDelta)
                        * Double(max(sample.onlineCPUs, 1)) * 100.0
                }
            }
            baseline[id] = (sample.cpuTotalUsage, sample.systemCPUUsage)
        }
        loadCPUBaseline = baseline

        return ContainerLoad(cpuPercent: cpuPercent, memoryUsedBytes: memoryUsed, sampled: samples.count)
    }

    /// Prunes the builder cache. Returns the reclaimed space report.
    public func pruneBuildCache() async -> PruneResult? {
        await mutateValue { try await $0.pruneBuildCache() }
    }

    /// Raw network inspect decoded into a minimal shape exposing the connected
    /// containers, used by `NetworkDetailView` to list attachments. Reuses the
    /// existing `rawInspectNetwork` so no new endpoint is required.
    public func networkContainers(id: String) async -> [NetworkAttachedContainer] {
        let json = await rawInspectNetwork(id: id)
        guard let data = json.data(using: .utf8) else { return [] }
        return NetworkAttachedContainer.decode(fromInspect: data)
    }
}

/// Aggregate live load across a host's running containers, for the Overview
/// dashboard. CPU is the sum of per-container percentages (100 = one core).
public struct ContainerLoad: Sendable, Hashable {
    public let cpuPercent: Double
    public let memoryUsedBytes: Int64
    /// How many running containers the sample covers.
    public let sampled: Int
}

/// One point of a host's rolling load history (`HostSession.loadHistory`).
public struct LoadSample: Identifiable, Sendable {
    public let id = UUID()
    public let date: Date
    /// 0…1 of the host's total CPU capacity.
    public let cpuFraction: Double
    /// Sum of per-container CPU percentages (100 = one core).
    public let cpuPercent: Double
    /// 0…1 of the host's physical memory.
    public let memFraction: Double
    public let memBytes: Int64
    /// How many running containers the sample covers.
    public let sampled: Int
}

extension HostSession {
    /// Starts (or restarts) the background load sampler. One sample every 5 s
    /// per host, independent of every other host and of what's on screen.
    private func startLoadSampling() {
        loadSamplingTask?.cancel()
        loadSamplingTask = Task { [weak self] in
            // Establish the CPU delta baseline right away so the first
            // recorded sample carries a real CPU figure, not zero.
            _ = await self?.containerLoad()
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                guard let self else { return }
                await self.recordLoadSample()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func recordLoadSample() async {
        guard status.isConnected, let info, let load = await containerLoad() else { return }
        let cpuCapacity = Double(max(info.ncpu, 1)) * 100.0
        let memTotal = Double(max(info.memTotal, 1))
        loadHistory.append(
            LoadSample(
                date: .now,
                cpuFraction: min(load.cpuPercent / cpuCapacity, 1.0),
                cpuPercent: load.cpuPercent,
                memFraction: min(Double(load.memoryUsedBytes) / memTotal, 1.0),
                memBytes: load.memoryUsedBytes,
                sampled: load.sampled
            )
        )
        if loadHistory.count > Self.loadHistoryWindow {
            loadHistory.removeFirst(loadHistory.count - Self.loadHistoryWindow)
        }
    }
}

/// One container attached to a network, decoded from the `Containers` map of a
/// raw network inspect (`GET /networks/{id}`). Kept local to AppCore so the
/// resource views can render attachments without a dedicated DockerKit model.
public struct NetworkAttachedContainer: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let ipv4Address: String
    public let ipv6Address: String

    public var displayName: String {
        name.isEmpty ? String(id.prefix(12)) : name
    }

    /// Decodes the `Containers` object of a network inspect body.
    static func decode(fromInspect data: Data) -> [NetworkAttachedContainer] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let map = root["Containers"] as? [String: Any]
        else { return [] }

        var result: [NetworkAttachedContainer] = []
        for (containerID, value) in map {
            let entry = value as? [String: Any] ?? [:]
            result.append(
                NetworkAttachedContainer(
                    id: containerID,
                    name: entry["Name"] as? String ?? "",
                    ipv4Address: entry["IPv4Address"] as? String ?? "",
                    ipv6Address: entry["IPv6Address"] as? String ?? ""
                )
            )
        }
        return result.sorted { $0.displayName.lowercased() < $1.displayName.lowercased() }
    }
}
