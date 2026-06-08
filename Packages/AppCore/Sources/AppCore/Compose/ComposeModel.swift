import Foundation

// A small, pragmatic model of a Docker Compose file — enough of the spec to
// turn a `docker-compose.yml` into a set of `container` CLI runs on an
// apple/container host. Parsing lives in `ComposeParser`; orchestration in
// `ComposeRunner`. Fields the runner cannot honor on apple/container (e.g.
// restart policies) are still parsed so we can warn rather than silently drop.

/// A parsed Compose project: its services, declared networks and volumes, plus
/// the on-disk location used to resolve relative build contexts and env files.
public struct ComposeProject: Sendable, Equatable {
    /// Project name. From the file's top-level `name:` if present, else the
    /// sanitized parent directory name (Compose's own default).
    public var name: String
    /// Services in declared order.
    public var services: [ComposeService]
    /// Declared named networks (key → definition). `default` is implicit.
    public var networks: [String: ComposeNetwork]
    /// Declared named volumes (key → definition).
    public var volumes: [String: ComposeVolume]
    /// Absolute path to the compose file on disk.
    public var filePath: URL
    /// Directory containing the compose file (build/env-file/bind-mount root).
    public var directory: URL

    public init(
        name: String,
        services: [ComposeService],
        networks: [String: ComposeNetwork] = [:],
        volumes: [String: ComposeVolume] = [:],
        filePath: URL,
        directory: URL
    ) {
        self.name = name
        self.services = services
        self.networks = networks
        self.volumes = volumes
        self.filePath = filePath
        self.directory = directory
    }
}

/// One service entry under `services:`.
public struct ComposeService: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// The service key (e.g. `web`).
    public var name: String
    /// `image:` reference. Optional when `build:` is present.
    public var image: String?
    /// `build:` context, if the service is built from source.
    public var build: ComposeBuild?
    /// `container_name:` override.
    public var containerName: String?
    /// `command:` (overrides the image CMD).
    public var command: [String]?
    /// `entrypoint:` (overrides the image ENTRYPOINT).
    public var entrypoint: [String]?
    /// `environment:` resolved to key→value (after interpolation).
    public var environment: [(key: String, value: String)]
    /// `env_file:` paths (relative to the project directory).
    public var envFiles: [String]
    /// `ports:` mappings.
    public var ports: [ComposePort]
    /// `volumes:` mounts (bind and named).
    public var volumes: [ComposeMount]
    /// `networks:` this service joins (keys into the project's networks).
    public var networks: [String]
    /// `depends_on:` service keys (start ordering).
    public var dependsOn: [String]
    /// `labels:` set on the container (compose labels added by the runner).
    public var labels: [String: String]
    /// `restart:` policy string (`no`, `always`, …). apple/container can't honor
    /// these, so the runner surfaces a warning instead of failing.
    public var restart: String?
    /// `working_dir:`.
    public var workingDir: String?
    /// `user:`.
    public var user: String?
    /// `tty:`.
    public var tty: Bool
    /// `privileged:`.
    public var privileged: Bool
    /// `mem_limit:` / `deploy.resources.limits.memory` in bytes.
    public var memoryBytes: Int64?
    /// `cpus:` / `deploy.resources.limits.cpus` in whole cores.
    public var cpus: Double?

    public init(
        name: String,
        image: String? = nil,
        build: ComposeBuild? = nil,
        containerName: String? = nil,
        command: [String]? = nil,
        entrypoint: [String]? = nil,
        environment: [(key: String, value: String)] = [],
        envFiles: [String] = [],
        ports: [ComposePort] = [],
        volumes: [ComposeMount] = [],
        networks: [String] = [],
        dependsOn: [String] = [],
        labels: [String: String] = [:],
        restart: String? = nil,
        workingDir: String? = nil,
        user: String? = nil,
        tty: Bool = false,
        privileged: Bool = false,
        memoryBytes: Int64? = nil,
        cpus: Double? = nil
    ) {
        self.name = name
        self.image = image
        self.build = build
        self.containerName = containerName
        self.command = command
        self.entrypoint = entrypoint
        self.environment = environment
        self.envFiles = envFiles
        self.ports = ports
        self.volumes = volumes
        self.networks = networks
        self.dependsOn = dependsOn
        self.labels = labels
        self.restart = restart
        self.workingDir = workingDir
        self.user = user
        self.tty = tty
        self.privileged = privileged
        self.memoryBytes = memoryBytes
        self.cpus = cpus
    }

    public static func == (lhs: ComposeService, rhs: ComposeService) -> Bool {
        lhs.name == rhs.name && lhs.image == rhs.image && lhs.build == rhs.build
            && lhs.containerName == rhs.containerName && lhs.command == rhs.command
            && lhs.entrypoint == rhs.entrypoint
            && lhs.environment.map { [$0.key, $0.value] } == rhs.environment.map { [$0.key, $0.value] }
            && lhs.envFiles == rhs.envFiles && lhs.ports == rhs.ports && lhs.volumes == rhs.volumes
            && lhs.networks == rhs.networks && lhs.dependsOn == rhs.dependsOn && lhs.labels == rhs.labels
            && lhs.restart == rhs.restart && lhs.workingDir == rhs.workingDir && lhs.user == rhs.user
            && lhs.tty == rhs.tty && lhs.privileged == rhs.privileged
            && lhs.memoryBytes == rhs.memoryBytes && lhs.cpus == rhs.cpus
    }
}

/// A service `build:` block.
public struct ComposeBuild: Sendable, Equatable {
    /// Build context directory (relative to the project directory, or absolute).
    public var context: String
    /// `dockerfile:` path relative to the context.
    public var dockerfile: String?
    /// `args:` build arguments.
    public var args: [String: String]
    /// `target:` build stage.
    public var target: String?

    public init(context: String, dockerfile: String? = nil, args: [String: String] = [:], target: String? = nil) {
        self.context = context
        self.dockerfile = dockerfile
        self.args = args
        self.target = target
    }
}

/// A `ports:` mapping (`"8080:80"`, `"127.0.0.1:8080:80/tcp"`, `"80"`).
public struct ComposePort: Sendable, Equatable {
    public var hostIP: String?
    /// Host port. Nil means "publish to an ephemeral port" (apple still needs a
    /// value; the runner mirrors the container port in that case).
    public var hostPort: String?
    public var containerPort: String
    /// `tcp` or `udp`.
    public var proto: String

    public init(hostIP: String? = nil, hostPort: String?, containerPort: String, proto: String = "tcp") {
        self.hostIP = hostIP
        self.hostPort = hostPort
        self.containerPort = containerPort
        self.proto = proto
    }
}

/// A `volumes:` entry on a service.
public struct ComposeMount: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Host path bind mount.
        case bind(hostPath: String)
        /// Named volume (key into the project's volumes).
        case named(volume: String)
    }
    public var kind: Kind
    public var containerPath: String
    public var readOnly: Bool

    public init(kind: Kind, containerPath: String, readOnly: Bool = false) {
        self.kind = kind
        self.containerPath = containerPath
        self.readOnly = readOnly
    }
}

/// A declared network under top-level `networks:`.
public struct ComposeNetwork: Sendable, Equatable {
    /// `external: true` — Compose expects the network to already exist; the
    /// runner does not create it.
    public var external: Bool
    /// `name:` override (external networks often pin a real name).
    public var name: String?
    public var labels: [String: String]

    public init(external: Bool = false, name: String? = nil, labels: [String: String] = [:]) {
        self.external = external
        self.name = name
        self.labels = labels
    }
}

/// A declared volume under top-level `volumes:`.
public struct ComposeVolume: Sendable, Equatable {
    public var external: Bool
    public var name: String?
    public var labels: [String: String]

    public init(external: Bool = false, name: String? = nil, labels: [String: String] = [:]) {
        self.external = external
        self.name = name
        self.labels = labels
    }
}

/// Thrown by `ComposeParser` when a file cannot be turned into a project.
public enum ComposeParseError: Error, LocalizedError, Equatable {
    case notReadable(String)
    case invalidYAML(String)
    case noServices
    case serviceMissingImageAndBuild(String)

    public var errorDescription: String? {
        switch self {
        case .notReadable(let p): "Can't read compose file: \(p)"
        case .invalidYAML(let m): "Invalid compose YAML: \(m)"
        case .noServices: "This file has no `services:` — it doesn't look like a Compose file."
        case .serviceMissingImageAndBuild(let s): "Service `\(s)` has neither `image:` nor `build:`."
        }
    }
}
