import Foundation

/// The rollout state of a deployment, stateful set or daemon set, with the
/// checks of `kubectl rollout status`.
public struct KubeRolloutStatus: Equatable, Sendable {
    public var done: Bool
    public var message: String

    public init(done: Bool, message: String) {
        self.done = done
        self.message = message
    }

    typealias Object = [String: Any]

    /// Reads the object JSON. Throws when the deployment missed its
    /// progress deadline.
    public static func evaluate(_ data: Data, kind: KubeResourceKind) throws -> KubeRolloutStatus {
        guard let object = try JSONSerialization.jsonObject(with: data) as? Object else { throw KubeAPIError.unexpectedResponse }
        let metadata = object["metadata"] as? Object ?? [:]
        let spec = object["spec"] as? Object ?? [:]
        let status = object["status"] as? Object ?? [:]
        let name = metadata["name"] as? String ?? ""
        let generation = int(metadata["generation"])
        let observed = int(status["observedGeneration"])
        guard observed >= generation else {
            return KubeRolloutStatus(done: false, message: String(localized: "Waiting for the controller to see the change of \(name)…", bundle: .module))
        }
        switch kind {
        case .deployments: return try deployment(name: name, spec: spec, status: status)
        case .statefulSets: return statefulSet(name: name, spec: spec, status: status)
        case .daemonSets: return daemonSet(name: name, status: status)
        default: return KubeRolloutStatus(done: true, message: "")
        }
    }

    static func deployment(name: String, spec: Object, status: Object) throws -> KubeRolloutStatus {
        let conditions = status["conditions"] as? [Object] ?? []
        if conditions.contains(where: { $0["type"] as? String == "Progressing" && $0["reason"] as? String == "ProgressDeadlineExceeded" }) {
            throw KubeAPIError.timedOut(String(localized: "The rollout of \(name) passed its progress deadline.", bundle: .module))
        }
        let desired = spec["replicas"] == nil ? 1 : int(spec["replicas"])
        let updated = int(status["updatedReplicas"])
        let total = int(status["replicas"])
        let available = int(status["availableReplicas"])
        if updated < desired {
            return waiting(String(localized: "Waiting for \(name). Updated replicas: \(updated) of \(desired).", bundle: .module))
        }
        if total > updated {
            return waiting(String(localized: "Waiting for \(name). Old replicas that must stop: \(total - updated).", bundle: .module))
        }
        if available < updated {
            return waiting(String(localized: "Waiting for \(name). Available replicas: \(available) of \(updated).", bundle: .module))
        }
        return finished(name)
    }

    static func statefulSet(name: String, spec: Object, status: Object) -> KubeRolloutStatus {
        let strategy = (spec["updateStrategy"] as? Object)?["type"] as? String ?? "RollingUpdate"
        guard strategy == "RollingUpdate" else { return finished(name) }
        let desired = spec["replicas"] == nil ? 1 : int(spec["replicas"])
        let ready = int(status["readyReplicas"])
        if ready < desired {
            return waiting(String(localized: "Waiting for \(name). Ready pods: \(ready) of \(desired).", bundle: .module))
        }
        let partition = int(((spec["updateStrategy"] as? Object)?["rollingUpdate"] as? Object)?["partition"])
        if partition > 0 {
            let updated = int(status["updatedReplicas"])
            let expected = max(0, desired - partition)
            if updated < expected {
                return waiting(String(localized: "Waiting for \(name). Updated pods: \(updated) of \(expected).", bundle: .module))
            }
            return finished(name)
        }
        if let update = status["updateRevision"] as? String, update != status["currentRevision"] as? String {
            let updated = int(status["updatedReplicas"])
            return waiting(String(localized: "Waiting for \(name). Updated pods: \(updated) of \(desired).", bundle: .module))
        }
        return finished(name)
    }

    static func daemonSet(name: String, status: Object) -> KubeRolloutStatus {
        let desired = int(status["desiredNumberScheduled"])
        let updated = int(status["updatedNumberScheduled"])
        let available = int(status["numberAvailable"])
        if updated < desired {
            return waiting(String(localized: "Waiting for \(name). Updated pods: \(updated) of \(desired).", bundle: .module))
        }
        if available < desired {
            return waiting(String(localized: "Waiting for \(name). Available pods: \(available) of \(desired).", bundle: .module))
        }
        return finished(name)
    }

    static func waiting(_ message: String) -> KubeRolloutStatus { KubeRolloutStatus(done: false, message: message) }

    static func finished(_ name: String) -> KubeRolloutStatus {
        KubeRolloutStatus(done: true, message: String(localized: "The rollout of \(name) is complete.", bundle: .module))
    }

    static func int(_ value: Any?) -> Int { KubeResourceParser.int(value) ?? 0 }
}
