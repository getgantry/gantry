import Foundation
import Citadel
import NIOCore
// NIOSSHUserAuthenticationOffer promises predate Sendable; same treatment
// Citadel itself uses.
@preconcurrency import NIOSSH

/// How to authenticate an SSH connection.
public enum AuthSource: Sendable {
    case key(LoadedKey)
    /// Candidate keys tried in order over a single connection, the way
    /// OpenSSH walks its identity files. Used by "automatic" auth where the
    /// right key for the server is not known up front.
    case keys([LoadedKey])
    case password(String)
}

/// One hop of a ProxyJump chain: where to connect and how to authenticate.
public struct SSHJumpHop: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: AuthSource

    public init(host: String, port: Int = 22, username: String, auth: AuthSource) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
    }
}

/// Everything required to open an SSH connection.
public struct SSHConnectionParameters: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var auth: AuthSource
    /// ProxyJump chain to reach `host`, outermost hop first (empty = direct).
    public var jumps: [SSHJumpHop]

    public init(
        host: String,
        port: Int = 22,
        username: String,
        auth: AuthSource,
        jumps: [SSHJumpHop] = []
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.auth = auth
        self.jumps = jumps
    }
}

/// The user's decision when presented with an unknown host key.
public enum HostKeyDecision: Sendable {
    case trust
    case reject
}

/// Asked to confirm an unknown host key for the given host ("host" or
/// "host:port"). Returns the user's decision. The host matters with
/// ProxyJump: the user must know whether they are trusting the bastion
/// or the destination.
public typealias HostKeyPrompt = @Sendable (String, HostKeyCandidate) async -> HostKeyDecision

/// Host key verification policy.
public enum HostKeyPolicy: Sendable {
    /// Accept keys already trusted via the store; for unknown keys, prompt the
    /// user and persist on acceptance. Mismatches are always rejected.
    case acceptKnown(KnownHostsStore, onUnknown: HostKeyPrompt)
}

/// Raised when a presented host key conflicts with a previously trusted one.
public struct HostKeyMismatchError: Error, LocalizedError, Sendable {
    public let host: String
    public let expectedFingerprint: String
    public let presentedFingerprint: String

    public var errorDescription: String? {
        """
        WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED for \(host).
        The host key fingerprint does not match the one previously trusted.
        Expected \(expectedFingerprint) but the server presented \(presentedFingerprint).
        This could mean someone is intercepting your connection (man-in-the-middle attack). \
        The connection was refused. If you changed the host key intentionally, remove the old \
        entry from the trusted hosts store before reconnecting.
        """
    }
}

/// Raised when the user declines to trust an unknown host key.
public struct UserRejectedHostKeyError: Error, LocalizedError, Sendable {
    public var errorDescription: String? {
        "The host key was not trusted, so the connection was cancelled."
    }
}

/// High-level errors surfaced by `SSHConnector.connect`.
public enum SSHConnectError: Error, LocalizedError, Sendable {
    case unreachable(String)
    case authenticationFailed(String)
    case hostKeyRejected
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .unreachable(let detail):
            "Could not reach the SSH host: \(detail)"
        case .authenticationFailed(let detail):
            "SSH authentication failed: \(detail)"
        case .hostKeyRejected:
            "The SSH host key was rejected."
        case .other(let detail):
            "SSH connection failed: \(detail)"
        }
    }
}

/// Bridges key loading, host key verification and Citadel into a single
/// connect entry point.
public final class SSHConnector: Sendable {
    /// Opens an SSH connection, performing host key verification per `policy`.
    /// When `parameters.jumps` is non-empty, hops are dialed in order and each
    /// next connection is tunneled through the previous one (ProxyJump), with
    /// per-hop authentication and host key verification.
    public static func connect(
        parameters: SSHConnectionParameters,
        policy: HostKeyPolicy
    ) async throws -> SSHClient {
        do {
            guard let first = parameters.jumps.first else {
                return try await dialDirect(parameters: parameters, policy: policy)
            }

            // Outermost hop is a plain TCP dial…
            var client = try await dialDirect(
                parameters: SSHConnectionParameters(
                    host: first.host,
                    port: first.port,
                    username: first.username,
                    auth: first.auth
                ),
                policy: policy
            )
            // …each subsequent hop and the target ride inside the previous one.
            for hop in parameters.jumps.dropFirst() {
                client = try await client.jump(
                    to: settings(host: hop.host, port: hop.port, username: hop.username, auth: hop.auth, policy: policy)
                )
            }
            return try await client.jump(
                to: settings(
                    host: parameters.host,
                    port: parameters.port,
                    username: parameters.username,
                    auth: parameters.auth,
                    policy: policy
                )
            )
        } catch {
            throw mapConnectError(error)
        }
    }

    private static func dialDirect(
        parameters: SSHConnectionParameters,
        policy: HostKeyPolicy
    ) async throws -> SSHClient {
        try await SSHClient.connect(
            host: parameters.host,
            port: parameters.port,
            authenticationMethod: authMethod(
                username: parameters.username,
                auth: parameters.auth
            ),
            hostKeyValidator: validator(host: parameters.host, port: parameters.port, policy: policy),
            reconnect: .never
        )
    }

    private static func settings(
        host: String,
        port: Int,
        username: String,
        auth: AuthSource,
        policy: HostKeyPolicy
    ) -> SSHClientSettings {
        SSHClientSettings(
            host: host,
            port: port,
            authenticationMethod: { authMethod(username: username, auth: auth) },
            hostKeyValidator: validator(host: host, port: port, policy: policy)
        )
    }

    private static func authMethod(username: String, auth: AuthSource) -> SSHAuthenticationMethod {
        switch auth {
        case .key(let key):
            key.authMethod(username: username)
        case .keys(let candidates) where candidates.count == 1:
            candidates[0].authMethod(username: username)
        case .keys(let candidates):
            .custom(MultiKeyAuthDelegate(username: username, keys: candidates))
        case .password(let password):
            .passwordBased(username: username, password: password)
        }
    }

    private static func validator(host: String, port: Int, policy: HostKeyPolicy) -> SSHHostKeyValidator {
        switch policy {
        case .acceptKnown(let store, let onUnknown):
            .custom(HostKeyVerifier(host: host, port: port, store: store, onUnknown: onUnknown))
        }
    }

    /// Best-effort mapping of Citadel/NIO connect errors to `SSHConnectError`.
    private static func mapConnectError(_ error: Error) -> Error {
        // Host key rejections flow up untouched so callers can read their detail.
        if error is HostKeyMismatchError { return error }
        if error is UserRejectedHostKeyError { return SSHConnectError.hostKeyRejected }

        if error is AuthenticationFailed {
            return SSHConnectError.authenticationFailed("invalid credentials")
        }
        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return SSHConnectError.authenticationFailed(String(describing: clientError))
            case .channelCreationFailed:
                return SSHConnectError.unreachable("channel creation failed")
            }
        }

        let description = String(describing: error).lowercased()
        if description.contains("auth") {
            return SSHConnectError.authenticationFailed(error.localizedDescription)
        }
        if description.contains("connection refused")
            || description.contains("timed out")
            || description.contains("timeout")
            || description.contains("unreachable")
            || description.contains("name or service not known")
            || description.contains("nodename")
            || description.contains("connect") {
            return SSHConnectError.unreachable(error.localizedDescription)
        }
        return SSHConnectError.other(error.localizedDescription)
    }
}

/// Offers each candidate private key in turn over a single connection:
/// NIOSSH calls `nextAuthenticationType` again after every rejected attempt,
/// which is exactly how OpenSSH walks its identity files. Internal (not
/// private) for unit testing.
final class MultiKeyAuthDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    /// Keys not yet offered; consumed front-to-back, one per attempt.
    private var remaining: [LoadedKey]

    init(username: String, keys: [LoadedKey]) {
        self.username = username
        self.remaining = keys
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(SSHClientError.unsupportedPrivateKeyAuthentication)
            return
        }
        guard !remaining.isEmpty else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        let key = remaining.removeFirst()
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: key.nioOffer())
        )
    }
}

/// Bridges Citadel's event-loop host key callback to the async prompt flow.
private final class HostKeyVerifier: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let host: String
    private let port: Int
    private let store: KnownHostsStore
    private let onUnknown: HostKeyPrompt

    init(host: String, port: Int, store: KnownHostsStore, onUnknown: @escaping HostKeyPrompt) {
        self.host = host
        self.port = port
        self.store = store
        self.onUnknown = onUnknown
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // Serialize "type base64 [comment]" then split off the leading two fields.
        let serialized = String(openSSHPublicKey: hostKey)
        let fields = serialized.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard fields.count >= 2 else {
            validationCompletePromise.fail(SSHConnectError.other("could not serialize host key"))
            return
        }
        let presented = HostKeyCandidate(keyType: String(fields[0]), base64: String(fields[1]))

        // Do not block the event loop; bridge into a Task.
        let host = host
        let port = port
        let store = store
        let onUnknown = onUnknown

        validationCompletePromise.completeWithTask {
            switch store.evaluate(host: host, port: port, presented: presented) {
            case .trusted:
                return
            case .mismatch(let expected):
                throw HostKeyMismatchError(
                    host: host,
                    expectedFingerprint: expected,
                    presentedFingerprint: presented.fingerprintSHA256
                )
            case .unknown:
                let label = port == 22 ? host : "\(host):\(port)"
                if await onUnknown(label, presented) == .trust {
                    store.persist(host: host, port: port, candidate: presented)
                    return
                } else {
                    throw UserRejectedHostKeyError()
                }
            }
        }
    }
}
