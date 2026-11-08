import Foundation

/// The resource types that the Kubernetes browser lists.
public enum KubeResourceKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case pods
    case deployments
    case statefulSets
    case daemonSets
    case services
    case ingresses
    case configMaps
    case secrets
    case nodes
    case events

    public var id: String { rawValue }

    /// The plural resource name in API paths (`/api/v1/pods`).
    public var resourceName: String {
        switch self {
        case .pods: "pods"
        case .deployments: "deployments"
        case .statefulSets: "statefulsets"
        case .daemonSets: "daemonsets"
        case .services: "services"
        case .ingresses: "ingresses"
        case .configMaps: "configmaps"
        case .secrets: "secrets"
        case .nodes: "nodes"
        case .events: "events"
        }
    }

    /// The prefix of an object reference (`deployment/web`).
    public var singularName: String {
        switch self {
        case .pods: "pod"
        case .deployments: "deployment"
        case .statefulSets: "statefulset"
        case .daemonSets: "daemonset"
        case .services: "service"
        case .ingresses: "ingress"
        case .configMaps: "configmap"
        case .secrets: "secret"
        case .nodes: "node"
        case .events: "event"
        }
    }

    public var title: String {
        switch self {
        case .pods: String(localized: "Pods", bundle: .module)
        case .deployments: String(localized: "Deployments", bundle: .module)
        case .statefulSets: String(localized: "Stateful Sets", bundle: .module)
        case .daemonSets: String(localized: "Daemon Sets", bundle: .module)
        case .services: String(localized: "Services", bundle: .module)
        case .ingresses: String(localized: "Ingresses", bundle: .module)
        case .configMaps: String(localized: "Config Maps", bundle: .module)
        case .secrets: String(localized: "Secrets", bundle: .module)
        case .nodes: String(localized: "Nodes", bundle: .module)
        case .events: String(localized: "Events", bundle: .module)
        }
    }

    public var systemImage: String {
        switch self {
        case .pods: "cube"
        case .deployments: "square.stack.3d.up"
        case .statefulSets: "cylinder.split.1x2"
        case .daemonSets: "square.grid.3x3"
        case .services: "point.3.connected.trianglepath.dotted"
        case .ingresses: "arrow.down.right.and.arrow.up.left"
        case .configMaps: "doc.text"
        case .secrets: "key"
        case .nodes: "server.rack"
        case .events: "bell"
        }
    }

    /// The API group and version path: `/api/v1` or `/apis/apps/v1`.
    public var apiPrefix: String {
        switch self {
        case .pods, .services, .configMaps, .secrets, .nodes, .events: "/api/v1"
        case .deployments, .statefulSets, .daemonSets: "/apis/apps/v1"
        case .ingresses: "/apis/networking.k8s.io/v1"
        }
    }

    /// False for cluster-wide resources.
    public var isNamespaced: Bool { self != .nodes }
    public var canScale: Bool { self == .deployments || self == .statefulSets }
    /// A rollout restart works for these.
    public var canRestart: Bool { self == .deployments || self == .statefulSets || self == .daemonSets }
    public var canDelete: Bool { self != .events }
    public var hasLogs: Bool { self == .pods }
    public var canExec: Bool { self == .pods }
    public var canPortForward: Bool { self == .pods || self == .services }
}

/// The health of a resource. Views show it with an icon and a text.
public enum KubeHealth: String, Sendable, Hashable {
    case ok
    case progressing
    case warning
    case failed
    case neutral
}

/// One label and value of a resource summary.
public struct KubeField: Hashable, Sendable {
    public var label: String
    public var value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// A port that a port forward can use.
public struct KubePort: Hashable, Sendable {
    public var port: Int
    public var name: String?
    public var proto: String

    public init(port: Int, name: String? = nil, proto: String = "TCP") {
        self.port = port
        self.name = name
        self.proto = proto
    }
}

/// One object of an API list, reduced for the browser.
public struct KubeResource: Identifiable, Hashable, Sendable {
    public var kind: KubeResourceKind
    public var name: String
    public var namespace: String?
    public var uid: String
    public var createdAt: Date?
    /// The short status, for example `Running`, `CrashLoopBackOff` or `2/3`.
    public var status: String
    public var health: KubeHealth
    /// The summary fields, in display order.
    public var fields: [KubeField]
    /// Container names of a pod, for logs and exec.
    public var containers: [String]
    public var ports: [KubePort]
    /// The desired replicas of a deployment or stateful set.
    public var replicas: Int?
    /// The time of the last event (events only).
    public var lastSeen: Date?

    public var id: String { uid.isEmpty ? "\(namespace ?? "")/\(kind.rawValue)/\(name)" : uid }

    /// `deployment/web`, for titles and messages.
    public var reference: String { "\(kind.singularName)/\(name)" }

    public init(
        kind: KubeResourceKind,
        name: String,
        namespace: String? = nil,
        uid: String = "",
        createdAt: Date? = nil,
        status: String = "",
        health: KubeHealth = .neutral,
        fields: [KubeField] = [],
        containers: [String] = [],
        ports: [KubePort] = [],
        replicas: Int? = nil,
        lastSeen: Date? = nil
    ) {
        self.kind = kind
        self.name = name
        self.namespace = namespace
        self.uid = uid
        self.createdAt = createdAt
        self.status = status
        self.health = health
        self.fields = fields
        self.containers = containers
        self.ports = ports
        self.replicas = replicas
        self.lastSeen = lastSeen
    }

    /// The value of the field with `label`, for tests and search.
    public func field(_ label: String) -> String? {
        fields.first { $0.label == label }?.value
    }
}
