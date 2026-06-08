import Foundation

/// A container engine the app can connect to: the local Docker daemon, a
/// remote one over SSH, or the local apple/container services (driven through
/// the `container` CLI).
public struct DockerHost: Identifiable, Hashable, Codable, Sendable {
    public enum Kind: Hashable, Codable, Sendable {
        case local
        case ssh(SSHEndpoint)
        case appleContainer
    }

    public var id: UUID
    public var name: String
    public var kind: Kind
    /// Optional explicit socket path override for local hosts. For
    /// apple/container hosts this overrides the `container` CLI path instead.
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

    public var isSSH: Bool {
        if case .ssh = kind { return true }
        return false
    }

    public var isAppleContainer: Bool {
        if case .appleContainer = kind { return true }
        return false
    }

    /// Whether the user is allowed to remove this host. The local daemon host
    /// is permanent; SSH and apple/container hosts can be removed.
    public var removable: Bool {
        !isLocal
    }

    /// What the host's engine supports. Docker-backed hosts (local and SSH)
    /// support everything; apple/container lacks several daemon features, and
    /// the UI hides those controls instead of surfacing 501 errors.
    public var capabilities: HostCapabilities {
        isAppleContainer ? .appleContainer : .docker
    }

    /// Small SF Symbol badge shown next to the host name in lists and cards;
    /// nil for the plain local daemon.
    public var badgeSystemImage: String? {
        switch kind {
        case .local: nil
        case .ssh: "network"
        case .appleContainer: "apple.logo"
        }
    }
}

/// Feature switches per engine, consulted by the UI to hide controls a host's
/// engine cannot honor.
public struct HostCapabilities: Hashable, Sendable {
    /// Pausing/unpausing containers.
    public var pauseResume: Bool
    /// Renaming an existing container.
    public var renameContainer: Bool
    /// Committing a container to a new image.
    public var commitContainer: Bool
    /// Changing a container's restart policy (incl. setting one at creation).
    public var restartPolicy: Bool
    /// Attaching/detaching running containers to networks.
    public var networkAttach: Bool
    /// Pruning the builder cache.
    public var buildCachePrune: Bool
    /// Image layer history.
    public var imageHistory: Bool
    /// Downloading/uploading files via the archive endpoints (the shell-based
    /// directory listing works either way). Covers drag-out / download and the
    /// native archive upload.
    public var containerFileTransfer: Bool
    /// Uploading files and folders into a container. True for Docker (native
    /// archive endpoint) and apple/container (emulated with `tar` over exec),
    /// even though the latter has no download/drag-out support.
    public var containerUpload: Bool

    /// Docker engine: everything on.
    public static let docker = HostCapabilities(
        pauseResume: true,
        renameContainer: true,
        commitContainer: true,
        restartPolicy: true,
        networkAttach: true,
        buildCachePrune: true,
        imageHistory: true,
        containerFileTransfer: true,
        containerUpload: true
    )

    /// apple/container: lifecycle, logs, exec, stats, images, volumes and
    /// networks work; the rest has no CLI equivalent.
    public static let appleContainer = HostCapabilities(
        pauseResume: false,
        renameContainer: false,
        commitContainer: false,
        restartPolicy: false,
        networkAttach: false,
        buildCachePrune: false,
        imageHistory: false,
        containerFileTransfer: false,
        containerUpload: true
    )
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
