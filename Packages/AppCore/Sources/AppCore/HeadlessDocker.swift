import Foundation
import DockerKit
import SSHKit

/// Headless, GUI-free Docker access used by App Intents (and the embedded MCP
/// server). Mirrors `HostSession`'s connect logic but without any interactive
/// prompts: secrets come only from the Keychain / disk, and unknown SSH host
/// keys are rejected outright (no trust-on-first-use in a headless context).
///
/// This is a SHARED CONTRACT: other components code against these exact
/// signatures. Keep them stable.
public enum HeadlessDocker {
    // MARK: - Host loading

    /// Reads the persisted host list from the same `hosts.json` that `AppModel`
    /// uses. Returns an empty array if the file is missing or unreadable; a
    /// single default Local host is *not* synthesised here (that is the GUI's
    /// first-run concern). Callers that need a Local fallback can append one.
    public static func loadHosts() -> [DockerHost] {
        guard let url = HostsStore.fileURL(),
              let data = try? Data(contentsOf: url) else {
            return []
        }
        let decoder = JSONDecoder()
        return (try? decoder.decode([DockerHost].self, from: data)) ?? []
    }

    // MARK: - Connecting

    /// Connects to a host and returns a negotiated `DockerClient`. The caller
    /// owns the returned client and must call `await client.shutdown()` when
    /// finished. Throws a descriptive `HeadlessDockerError` on failure.
    public static func connect(to host: DockerHost) async throws -> DockerClient {
        let transport: DockerTransport
        switch host.kind {
        case .local:
            transport = try makeLocalTransport(for: host)
        case .ssh(let endpoint):
            transport = try await makeSSHTransport(for: host, endpoint: endpoint)
        }

        let client = DockerClient(transport: transport)
        do {
            _ = try await client.negotiate()
        } catch {
            await client.shutdown()
            throw HeadlessDockerError.connectionFailed(
                "Could not reach the Docker daemon on \(host.name): \(error.localizedDescription)"
            )
        }
        return client
    }

    // MARK: - Local transport

    private static func makeLocalTransport(for host: DockerHost) throws -> DockerTransport {
        let socketPath = host.socketPathOverride ?? DockerSocketDiscovery.discover()
        guard let socketPath else {
            throw HeadlessDockerError.noLocalSocket
        }
        return UnixSocketTransport(socketPath: socketPath)
    }

    // MARK: - SSH transport

    /// Builds an SSH transport using the same resolution rules as
    /// `HostSession.connectSSH`, but headless: a TRUSTED-ONLY host key policy
    /// (`onUnknown` rejects) and Keychain/disk-only credential resolution.
    private static func makeSSHTransport(
        for host: DockerHost,
        endpoint: SSHEndpoint
    ) async throws -> DockerTransport {
        let resolved = SSHConfig.resolve(host: endpoint.host)

        let hostName = endpoint.host.isEmpty ? resolved.hostName : endpoint.host
        let port = endpoint.port != 0 ? endpoint.port : resolved.port
        let username: String = {
            if !endpoint.username.isEmpty { return endpoint.username }
            if let user = resolved.user, !user.isEmpty { return user }
            return NSUserName()
        }()

        // TRUSTED-ONLY: unknown host keys are rejected; we never TOFU headless.
        let knownHosts = KnownHostsStore()
        let policy = HostKeyPolicy.acceptKnown(knownHosts) { _ in .reject }

        let auth = try resolveAuth(
            host: host,
            endpoint: endpoint,
            resolvedIdentityFiles: resolved.identityFiles
        )

        let parameters = SSHConnectionParameters(
            host: hostName,
            port: port,
            username: username,
            auth: auth
        )

        return SSHDialStdioTransport {
            try await SSHConnector.connect(parameters: parameters, policy: policy)
        }
    }

    /// Resolves SSH authentication from non-interactive sources only. Mirrors
    /// `HostSession.resolveAuth`, but a missing secret is a hard error here
    /// (no user prompt is possible in a headless context).
    private static func resolveAuth(
        host: DockerHost,
        endpoint: SSHEndpoint,
        resolvedIdentityFiles: [String]
    ) throws -> AuthSource {
        switch endpoint.auth {
        case .automatic:
            let candidates = resolvedIdentityFiles + SSHKeyLoader.defaultKeyCandidates()
            return try loadFirstUsableKey(from: candidates, hostID: host.id, hostName: host.name)

        case .keyFile(let path):
            return try loadFirstUsableKey(from: [path], hostID: host.id, hostName: host.name)

        case .password:
            let account = KeychainStore.sshPasswordAccount(hostID: host.id)
            guard let stored = KeychainStore.get(account: account) else {
                throw HeadlessDockerError.missingCredential(
                    "No saved SSH password for \(host.name). Connect once from the Gantry app to store it in the Keychain."
                )
            }
            return .password(stored)
        }
    }

    /// Tries each candidate key path in order, returning the first that loads.
    /// Passphrase-protected keys are unlocked only via the Keychain (no prompt).
    private static func loadFirstUsableKey(
        from paths: [String],
        hostID: UUID,
        hostName: String
    ) throws -> AuthSource {
        let passphraseAccount = KeychainStore.keyPassphraseAccount(hostID: hostID)
        var lastError: Error?

        for path in paths {
            do {
                let key = try SSHKeyLoader.load(contentsOf: path, passphrase: nil)
                return .key(key)
            } catch SSHKeyError.needsPassphrase {
                // A stored passphrase is the only non-interactive option.
                guard let stored = KeychainStore.get(account: passphraseAccount),
                      let key = try? SSHKeyLoader.load(contentsOf: path, passphrase: stored) else {
                    lastError = HeadlessDockerError.missingCredential(
                        "The SSH key at \(path) is passphrase-protected and no passphrase is saved for \(hostName). Connect once from the Gantry app to store it."
                    )
                    continue
                }
                return .key(key)
            } catch {
                // Unloadable / missing file: try the next candidate.
                lastError = error
                continue
            }
        }

        throw lastError ?? HeadlessDockerError.missingCredential(
            "No usable SSH key found for \(hostName)."
        )
    }
}

/// Descriptive errors surfaced by `HeadlessDocker`.
public enum HeadlessDockerError: Error, LocalizedError, Sendable {
    case noLocalSocket
    case missingCredential(String)
    case connectionFailed(String)
    case hostNotFound(String)
    case containerNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .noLocalSocket:
            "No local Docker socket was found. Make sure Docker is running."
        case .missingCredential(let detail):
            detail
        case .connectionFailed(let detail):
            detail
        case .hostNotFound(let detail):
            "Docker host not found: \(detail)"
        case .containerNotFound(let detail):
            "Container not found: \(detail)"
        }
    }
}
