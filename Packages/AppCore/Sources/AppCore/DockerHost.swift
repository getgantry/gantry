import Foundation

/// A Docker endpoint the app can connect to: the local daemon or a remote one over SSH.
public struct DockerHost: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case local
        case ssh(SSHEndpoint)
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Optional explicit socket path override for local hosts.
    public var socketPathOverride: String?

    public init(id: UUID = UUID(), name: String, kind: Kind, socketPathOverride: String? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.socketPathOverride = socketPathOverride
    }

    public var isLocal: Bool {
        if case .local = kind { return true }
        return false
    }

    /// Whether the user is allowed to remove this host. The local daemon host
    /// is permanent; SSH hosts can be removed.
    public var removable: Bool {
        !isLocal
    }
}

/// How Gantry authenticates an SSH connection to a remote Docker host.
public enum SSHAuthMode: Hashable, Codable, Sendable {
    /// Resolve credentials from ssh_config plus the standard default key candidates.
    case automatic
    /// Use a specific private key file at the given path.
    case keyFile(String)
    /// Password authentication; the secret lives in the Keychain.
    case password
}

/// Connection parameters for an SSH-reachable Docker host.
public struct SSHEndpoint: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// Path to the private key file; nil means password auth.
    public var identityFile: String?
    /// How to authenticate; defaults to `.automatic` for backward compatibility.
    public var auth: SSHAuthMode

    public init(
        host: String,
        port: Int = 22,
        username: String = "",
        identityFile: String? = nil,
        auth: SSHAuthMode = .automatic
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
        self.auth = auth
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case port
        case username
        case identityFile
        case auth
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 22
        username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
        identityFile = try container.decodeIfPresent(String.self, forKey: .identityFile)
        // Missing field (older persisted hosts) -> .automatic.
        auth = try container.decodeIfPresent(SSHAuthMode.self, forKey: .auth) ?? .automatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(port, forKey: .port)
        try container.encode(username, forKey: .username)
        try container.encodeIfPresent(identityFile, forKey: .identityFile)
        try container.encode(auth, forKey: .auth)
    }
}
