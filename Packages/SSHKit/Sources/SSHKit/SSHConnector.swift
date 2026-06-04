import Foundation
import Citadel
import NIOCore
import NIOSSH

/// How to authenticate an SSH connection.
public enum AuthSource: Sendable {
    case key(LoadedKey)
    case password(String)
}

/// Everything required to open an SSH connection.
public struct SSHConnectionParameters: Sendable {
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

/// The user's decision when presented with an unknown host key.
public enum HostKeyDecision: Sendable {
    case trust
    case reject
}

/// Asked to confirm an unknown host key. Returns the user's decision.
public typealias HostKeyPrompt = @Sendable (HostKeyCandidate) async -> HostKeyDecision

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
    public static func connect(
        parameters: SSHConnectionParameters,
        policy: HostKeyPolicy
    ) async throws -> SSHClient {
        let authMethod: SSHAuthenticationMethod
        var usedRSAKey = false
        switch parameters.auth {
        case .key(let key):
            if case .rsa = key { usedRSAKey = true }
            authMethod = key.authMethod(username: parameters.username)
        case .password(let password):
            authMethod = .passwordBased(username: parameters.username, password: password)
        }

        let validator: SSHHostKeyValidator
        switch policy {
        case .acceptKnown(let store, let onUnknown):
            let delegate = HostKeyVerifier(
                host: parameters.host,
                port: parameters.port,
                store: store,
                onUnknown: onUnknown
            )
            validator = .custom(delegate)
        }

        do {
            return try await SSHClient.connect(
                host: parameters.host,
                port: parameters.port,
                authenticationMethod: authMethod,
                hostKeyValidator: validator,
                reconnect: .never
            )
        } catch {
            let mapped = mapConnectError(error)
            // The SSH library signs RSA keys with the legacy ssh-rsa (SHA-1)
            // algorithm, which modern OpenSSH servers reject. Give users an
            // actionable hint instead of a bare auth failure.
            if usedRSAKey, case SSHConnectError.authenticationFailed(let detail) = mapped {
                throw SSHConnectError.authenticationFailed(
                    detail + " — note: RSA keys are signed as legacy ssh-rsa, which modern servers reject. Use an ed25519 key instead (ssh-keygen -t ed25519)."
                )
            }
            throw mapped
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
                if await onUnknown(presented) == .trust {
                    store.persist(host: host, port: port, candidate: presented)
                    return
                } else {
                    throw UserRejectedHostKeyError()
                }
            }
        }
    }
}
