import Foundation
import DockerKit
import SSHKit
import AppCore

/// Headless Docker access for the MCP server.
///
/// Mirrors the connection logic of the app's `HostSession` but without any UI:
/// it loads the persisted host list, dials the local socket or a remote daemon
/// over SSH, and caches one live `DockerClient` per host id for the lifetime of
/// the process.
///
/// SSH connections are *trusted-only*: a remote host key that is neither in the
/// app's trusted store nor in `~/.ssh/known_hosts` is rejected outright (no
/// interactive trust-on-first-use prompt is possible in a headless context).
/// Passphrase-protected keys are unlocked only from the Keychain; there is no
/// interactive passphrase prompt either.
actor HeadlessDocker {
    /// Cached, already-negotiated clients keyed by host id.
    private var clients: [UUID: DockerClient] = [:]

    init() {}

    // MARK: - Host list

    /// Loads the persisted host list (the same `hosts.json` the app writes),
    /// seeding the default local host when no file exists yet.
    nonisolated func loadHosts() -> [DockerHost] {
        let hosts = AppCore.HeadlessDocker.loadHosts()
        return hosts.isEmpty ? [DockerHost(name: "Local", kind: .local)] : hosts
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

        let transport: DockerTransport
        switch host.kind {
        case .local:
            let socketPath = host.socketPathOverride ?? DockerSocketDiscovery.discover()
            guard let socketPath else {
                throw HeadlessError.noSocket
            }
            transport = UnixSocketTransport(socketPath: socketPath)

        case .ssh(let endpoint):
            transport = try makeSSHTransport(endpoint: endpoint, hostID: host.id)
        }

        let client = DockerClient(transport: transport)
        do {
            try await client.negotiate()
        } catch {
            await client.shutdown()
            throw error
        }
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

    // MARK: - SSH (trusted-only, non-interactive)

    private nonisolated func makeSSHTransport(
        endpoint: SSHEndpoint,
        hostID: UUID
    ) throws -> DockerTransport {
        let resolved = ResolvedSSHEndpoint.resolve(endpoint)

        // Trusted-only: known hosts pass, everything else is rejected. No prompt.
        let knownHosts = KnownHostsStore()
        let policy = HostKeyPolicy.acceptKnown(knownHosts) { _ in .reject }

        let auth = try resolveAuth(
            endpoint: endpoint,
            hostID: hostID,
            resolvedIdentityFiles: resolved.identityFiles
        )

        let parameters = SSHConnectionParameters(
            host: resolved.hostName,
            port: resolved.port,
            username: resolved.username,
            auth: auth
        )

        return SSHDialStdioTransport {
            try await SSHConnector.connect(parameters: parameters, policy: policy)
        }
    }

    /// Resolves credentials without any interactive prompts. Keys load only if
    /// unencrypted or unlockable with a Keychain-stored passphrase; passwords
    /// come only from the Keychain.
    private nonisolated func resolveAuth(
        endpoint: SSHEndpoint,
        hostID: UUID,
        resolvedIdentityFiles: [String]
    ) throws -> AuthSource {
        switch endpoint.auth {
        case .automatic:
            let candidates = resolvedIdentityFiles + SSHKeyLoader.defaultKeyCandidates()
            return try loadFirstUsableKey(from: candidates, hostID: hostID)
        case .keyFile(let path):
            return try loadFirstUsableKey(from: [path], hostID: hostID)
        case .password:
            let account = KeychainStore.sshPasswordAccount(hostID: hostID)
            guard let stored = KeychainStore.get(account: account) else {
                throw HeadlessError.credentialsUnavailable
            }
            return .password(stored)
        }
    }

    private nonisolated func loadFirstUsableKey(
        from paths: [String],
        hostID: UUID
    ) throws -> AuthSource {
        let passphraseAccount = KeychainStore.keyPassphraseAccount(hostID: hostID)
        var lastError: Error?

        for path in paths {
            do {
                let key = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
                return .key(key)
            } catch SSHKeyError.needsPassphrase {
                // Only a stored passphrase can unlock it headlessly.
                if let stored = KeychainStore.get(account: passphraseAccount),
                   let key = try? SSHKeyLoader.load(contentsOf: path, passphrase: stored) {
                    return .key(key)
                }
                lastError = HeadlessError.credentialsUnavailable
                continue
            } catch {
                lastError = error
                continue
            }
        }

        throw lastError ?? HeadlessError.credentialsUnavailable
    }

}

enum HeadlessError: Error, LocalizedError {
    case noSocket
    case unknownHost(UUID)
    case credentialsUnavailable

    var errorDescription: String? {
        switch self {
        case .noSocket:
            return "No Docker socket found on this machine."
        case .unknownHost(let id):
            return "No host with id \(id.uuidString)."
        case .credentialsUnavailable:
            return "SSH credentials are unavailable headlessly. Connect to this host once in the Gantry app to trust its key and store any secret in the Keychain."
        }
    }
}
