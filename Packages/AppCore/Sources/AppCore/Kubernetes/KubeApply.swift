import Foundation
import Yams

/// One object of a manifest, ready for server-side apply.
public struct KubeApplyObject: Hashable, Sendable {
    public var apiVersion: String
    public var kind: String
    public var name: String
    public var namespace: String?
    /// The object as YAML, the body of the apply request.
    public var yaml: String

    /// `deployment.apps/web` (the kubectl form).
    public var reference: String {
        let group = apiVersion.contains("/") ? "." + (apiVersion.split(separator: "/").first.map(String.init) ?? "") : ""
        return "\(kind.lowercased())\(group)/\(name)"
    }
}

/// The plural name of a kind and whether it lives in a namespace.
public struct KubeAPIResource: Hashable, Sendable {
    public var plural: String
    public var namespaced: Bool

    public init(_ plural: String, namespaced: Bool) {
        self.plural = plural
        self.namespaced = namespaced
    }
}

/// The result of one object of an apply.
public struct KubeApplyResult: Identifiable, Hashable, Sendable {
    public enum Outcome: Hashable, Sendable {
        case created
        case configured
        case failed(String)
    }

    public var id: Int
    public var reference: String
    public var namespace: String?
    public var outcome: Outcome

    public var succeeded: Bool {
        if case .failed = outcome { false } else { true }
    }
}

public enum KubeApplyError: Error, LocalizedError, Equatable {
    case invalidYAML(String)
    case empty

    public var errorDescription: String? {
        switch self {
        case .invalidYAML(let message): String(localized: "The YAML is not valid: \(message)", bundle: .module)
        case .empty: String(localized: "The manifest has no objects.", bundle: .module)
        }
    }
}

/// Splits a manifest into objects and maps each one to its API path.
public enum KubeApplyPlanner {
    /// Kinds that the planner knows without discovery, by `group/Kind`
    /// (the core group is empty).
    static let builtIn: [String: KubeAPIResource] = [
        "/Pod": .init("pods", namespaced: true),
        "/Service": .init("services", namespaced: true),
        "/ConfigMap": .init("configmaps", namespaced: true),
        "/Secret": .init("secrets", namespaced: true),
        "/Namespace": .init("namespaces", namespaced: false),
        "/ServiceAccount": .init("serviceaccounts", namespaced: true),
        "/PersistentVolumeClaim": .init("persistentvolumeclaims", namespaced: true),
        "/PersistentVolume": .init("persistentvolumes", namespaced: false),
        "/Node": .init("nodes", namespaced: false),
        "/Endpoints": .init("endpoints", namespaced: true),
        "/LimitRange": .init("limitranges", namespaced: true),
        "/ResourceQuota": .init("resourcequotas", namespaced: true),
        "/ReplicationController": .init("replicationcontrollers", namespaced: true),
        "apps/Deployment": .init("deployments", namespaced: true),
        "apps/StatefulSet": .init("statefulsets", namespaced: true),
        "apps/DaemonSet": .init("daemonsets", namespaced: true),
        "apps/ReplicaSet": .init("replicasets", namespaced: true),
        "batch/Job": .init("jobs", namespaced: true),
        "batch/CronJob": .init("cronjobs", namespaced: true),
        "networking.k8s.io/Ingress": .init("ingresses", namespaced: true),
        "networking.k8s.io/IngressClass": .init("ingressclasses", namespaced: false),
        "networking.k8s.io/NetworkPolicy": .init("networkpolicies", namespaced: true),
        "rbac.authorization.k8s.io/Role": .init("roles", namespaced: true),
        "rbac.authorization.k8s.io/RoleBinding": .init("rolebindings", namespaced: true),
        "rbac.authorization.k8s.io/ClusterRole": .init("clusterroles", namespaced: false),
        "rbac.authorization.k8s.io/ClusterRoleBinding": .init("clusterrolebindings", namespaced: false),
        "storage.k8s.io/StorageClass": .init("storageclasses", namespaced: false),
        "policy/PodDisruptionBudget": .init("poddisruptionbudgets", namespaced: true),
        "autoscaling/HorizontalPodAutoscaler": .init("horizontalpodautoscalers", namespaced: true),
        "apiextensions.k8s.io/CustomResourceDefinition": .init("customresourcedefinitions", namespaced: false),
        "scheduling.k8s.io/PriorityClass": .init("priorityclasses", namespaced: false),
        "discovery.k8s.io/EndpointSlice": .init("endpointslices", namespaced: true),
    ]

    static func group(of apiVersion: String) -> String {
        apiVersion.contains("/") ? String(apiVersion.split(separator: "/")[0]) : ""
    }

    public static func knownResource(apiVersion: String, kind: String) -> KubeAPIResource? {
        builtIn["\(group(of: apiVersion))/\(kind)"]
    }

    /// The objects of a multi-document manifest, in file order. Empty
    /// documents are skipped; a `List` gives its items.
    public static func objects(from manifest: String) throws -> [KubeApplyObject] {
        let nodes: [Node]
        do {
            nodes = Array(try Yams.compose_all(yaml: manifest))
        } catch {
            throw KubeApplyError.invalidYAML(String(describing: error))
        }
        var result: [KubeApplyObject] = []
        for node in nodes {
            guard node.mapping != nil else {
                if node.null == nil { throw KubeApplyError.invalidYAML(String(localized: "Each document must be an object.", bundle: .module)) }
                continue
            }
            if node["kind"]?.string == "List", let items = node["items"]?.sequence {
                result += try items.map(object(from:))
            } else {
                result.append(try object(from: node))
            }
        }
        guard !result.isEmpty else { throw KubeApplyError.empty }
        return result
    }

    static func object(from node: Node) throws -> KubeApplyObject {
        let metadata = node["metadata"]
        return KubeApplyObject(
            apiVersion: node["apiVersion"]?.string ?? "",
            kind: node["kind"]?.string ?? "",
            name: metadata?["name"]?.string ?? "",
            namespace: metadata?["namespace"]?.string.flatMap { $0.isEmpty ? nil : $0 },
            yaml: try Yams.serialize(node: node, allowUnicode: true)
        )
    }

    /// The problem that stops an object before any request, or nil.
    public static func problem(_ object: KubeApplyObject) -> String? {
        if object.apiVersion.isEmpty { return String(localized: "The object has no apiVersion.", bundle: .module) }
        if object.kind.isEmpty { return String(localized: "The object has no kind.", bundle: .module) }
        if object.name.isEmpty { return String(localized: "The object has no metadata.name.", bundle: .module) }
        return nil
    }

    /// The path for the apply PATCH. A namespaced object without a
    /// namespace goes to `defaultNamespace`.
    public static func path(_ object: KubeApplyObject, resource: KubeAPIResource, defaultNamespace: String) -> String {
        let prefix = object.apiVersion.contains("/") ? "/apis/\(object.apiVersion)" : "/api/\(object.apiVersion)"
        let namespace = resource.namespaced ? (object.namespace ?? defaultNamespace) : nil
        return KubeRequests.collectionPath(prefix: prefix, resource: resource.plural, namespace: namespace)
            + "/" + KubeRequests.segment(object.name)
    }

    /// Finds `kind` in an APIResourceList (discovery of one group version).
    public static func resource(kind: String, inDiscovery data: Data) -> KubeAPIResource? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        for item in root["resources"] as? [[String: Any]] ?? [] {
            guard item["kind"] as? String == kind, let name = item["name"] as? String, !name.contains("/") else { continue }
            return KubeAPIResource(name, namespaced: item["namespaced"] as? Bool ?? true)
        }
        return nil
    }
}

extension KubeAPIClient {
    /// Applies every object of `manifest` with server-side apply
    /// (fieldManager gantry, no force). One failed object does not stop
    /// the others. Throws only when the YAML cannot be read.
    public func apply(_ manifest: String, defaultNamespace: String) async throws -> [KubeApplyResult] {
        let objects = try KubeApplyPlanner.objects(from: manifest)
        var discovered: [String: KubeAPIResource] = [:]
        var results: [KubeApplyResult] = []
        for (index, object) in objects.enumerated() {
            var result = KubeApplyResult(id: index, reference: object.reference, namespace: object.namespace, outcome: .configured)
            do {
                if let problem = KubeApplyPlanner.problem(object) { throw KubeAPIError.status(code: 0, reason: nil, message: problem) }
                let key = "\(object.apiVersion)/\(object.kind)"
                let resource: KubeAPIResource
                if let known = KubeApplyPlanner.knownResource(apiVersion: object.apiVersion, kind: object.kind) ?? discovered[key] {
                    resource = known
                } else {
                    let data = try await send(KubeRequests.discovery(apiVersion: object.apiVersion))
                    guard let found = KubeApplyPlanner.resource(kind: object.kind, inDiscovery: data) else {
                        throw KubeAPIError.status(code: 404, reason: "NotFound", message: String(
                            localized: "The cluster does not know the kind \(object.kind) in \(object.apiVersion).", bundle: .module))
                    }
                    discovered[key] = found
                    resource = found
                }
                if resource.namespaced { result.namespace = object.namespace ?? defaultNamespace }
                let path = KubeApplyPlanner.path(object, resource: resource, defaultNamespace: defaultNamespace)
                let (code, _) = try await sendWithStatus(KubeRequests.apply(path: path, yaml: object.yaml))
                result.outcome = code == 201 ? .created : .configured
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.outcome = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            results.append(result)
        }
        return results
    }
}
