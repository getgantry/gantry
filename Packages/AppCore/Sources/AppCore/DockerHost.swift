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
}

/// Connection parameters for an SSH-reachable Docker host.
public struct SSHEndpoint: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var username: String
    /// Path to the private key file; nil means password auth.
    public var identityFile: String?

    public init(host: String, port: Int = 22, username: String, identityFile: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
        self.identityFile = identityFile
    }
}
