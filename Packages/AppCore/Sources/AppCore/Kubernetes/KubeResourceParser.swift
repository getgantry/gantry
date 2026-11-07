import Foundation

/// The labels of resource summary fields.
public enum KubeFieldLabel {
    public static var ready: String { String(localized: "Ready", bundle: .module) }
    public static var restarts: String { String(localized: "Restarts", bundle: .module) }
    public static var node: String { String(localized: "Node", bundle: .module) }
    public static var podIP: String { String(localized: "Pod IP", bundle: .module) }
    public static var images: String { String(localized: "Images", bundle: .module) }
    public static var upToDate: String { String(localized: "Up to Date", bundle: .module) }
    public static var available: String { String(localized: "Available", bundle: .module) }
    public static var desired: String { String(localized: "Desired", bundle: .module) }
    public static var type: String { String(localized: "Type", bundle: .module) }
    public static var clusterIP: String { String(localized: "Cluster IP", bundle: .module) }
    public static var externalIP: String { String(localized: "External IP", bundle: .module) }
    public static var ports: String { String(localized: "Ports", bundle: .module) }
    public static var ingressClass: String { String(localized: "Class", bundle: .module) }
    public static var hosts: String { String(localized: "Hosts", bundle: .module) }
    public static var address: String { String(localized: "Address", bundle: .module) }
    public static var keys: String { String(localized: "Keys", bundle: .module) }
    public static var roles: String { String(localized: "Roles", bundle: .module) }
    public static var version: String { String(localized: "Version", bundle: .module) }
    public static var internalIP: String { String(localized: "Internal IP", bundle: .module) }
    public static var object: String { String(localized: "Object", bundle: .module) }
    public static var message: String { String(localized: "Message", bundle: .module) }
    public static var count: String { String(localized: "Count", bundle: .module) }
}

/// Parses `kubectl get <kind> -o json` output into ``KubeResource`` values.
public enum KubeResourceParser {
    typealias Object = [String: Any]

    /// Parses a `List` (or one object) of `kind`. Events come newest first.
    public static func parse(_ data: Data, kind: KubeResourceKind) throws -> [KubeResource] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? Object else {
            throw KubectlError.unexpectedOutput
        }
        let items = root["items"] as? [Object] ?? (root["metadata"] != nil ? [root] : [])
        let resources = items.map { resource(from: $0, kind: kind) }
        if kind == .events {
            return resources.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        }
        return resources
    }

    /// Parses `kubectl get namespaces -o json` into sorted names.
    public static func namespaces(_ data: Data) throws -> [String] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? Object else {
            throw KubectlError.unexpectedOutput
        }
        return (root["items"] as? [Object] ?? [])
            .compactMap { ($0["metadata"] as? Object)?["name"] as? String }
            .sorted()
    }

    static func resource(from item: Object, kind: KubeResourceKind) -> KubeResource {
        let metadata = item["metadata"] as? Object ?? [:]
        var resource = KubeResource(
            kind: kind,
            name: metadata["name"] as? String ?? "",
            namespace: kind.isNamespaced ? metadata["namespace"] as? String : nil,
            uid: metadata["uid"] as? String ?? "",
            createdAt: date(metadata["creationTimestamp"])
        )
        let spec = item["spec"] as? Object ?? [:]
        let status = item["status"] as? Object ?? [:]
        switch kind {
        case .pods: fillPod(&resource, metadata: metadata, spec: spec, status: status)
        case .deployments, .statefulSets: fillReplicated(&resource, spec: spec, status: status)
        case .daemonSets: fillDaemonSet(&resource, status: status)
        case .services: fillService(&resource, spec: spec, status: status)
        case .ingresses: fillIngress(&resource, spec: spec, status: status)
        case .configMaps:
            let count = ((item["data"] as? Object)?.count ?? 0) + ((item["binaryData"] as? Object)?.count ?? 0)
            resource.status = keyCount(count)
            resource.fields = [KubeField(KubeFieldLabel.keys, String(count))]
        case .secrets:
            let count = (item["data"] as? Object)?.count ?? 0
            resource.status = item["type"] as? String ?? "Opaque"
            resource.fields = [KubeField(KubeFieldLabel.keys, String(count))]
        case .nodes: fillNode(&resource, metadata: metadata, spec: spec, status: status)
        case .events: fillEvent(&resource, item: item)
        }
        return resource
    }

    // MARK: - Kinds

    static func fillPod(_ resource: inout KubeResource, metadata: Object, spec: Object, status: Object) {
        let containers = (spec["containers"] as? [Object] ?? [])
        resource.containers = containers.compactMap { $0["name"] as? String }
        resource.ports = containers.flatMap { container in
            (container["ports"] as? [Object] ?? []).compactMap { port in
                guard let number = int(port["containerPort"]) else { return nil }
                return KubePort(port: number, name: port["name"] as? String, proto: port["protocol"] as? String ?? "TCP")
            }
        }
        let statuses = status["containerStatuses"] as? [Object] ?? []
        let ready = statuses.filter { $0["ready"] as? Bool == true }.count
        let restarts = statuses.reduce(0) { $0 + (int($1["restartCount"]) ?? 0) }
        let (text, health) = podStatus(metadata: metadata, status: status, ready: ready, total: max(containers.count, statuses.count))
        resource.status = text
        resource.health = health
        resource.fields = [
            KubeField(KubeFieldLabel.ready, "\(ready)/\(max(containers.count, statuses.count))"),
            KubeField(KubeFieldLabel.restarts, String(restarts)),
            KubeField(KubeFieldLabel.node, spec["nodeName"] as? String ?? "—"),
            KubeField(KubeFieldLabel.podIP, status["podIP"] as? String ?? "—"),
            KubeField(KubeFieldLabel.images, containers.compactMap { $0["image"] as? String }.joined(separator: ", ")),
        ]
    }

    /// The status text that `kubectl get pods` prints, and its health.
    static func podStatus(metadata: Object, status: Object, ready: Int, total: Int) -> (String, KubeHealth) {
        if metadata["deletionTimestamp"] != nil { return ("Terminating", .progressing) }
        let phase = status["phase"] as? String ?? "Unknown"
        if let reason = status["reason"] as? String, !reason.isEmpty { return (reason, .failed) }
        for initStatus in status["initContainerStatuses"] as? [Object] ?? [] {
            let state = initStatus["state"] as? Object ?? [:]
            if let reason = (state["waiting"] as? Object)?["reason"] as? String, reason != "PodInitializing" {
                return ("Init:\(reason)", health(forReason: reason))
            }
            if let terminated = state["terminated"] as? Object, int(terminated["exitCode"]) != 0 {
                return ("Init:\(terminated["reason"] as? String ?? "Error")", .failed)
            }
            if state["running"] != nil { return ("Init:Running", .progressing) }
        }
        for containerStatus in status["containerStatuses"] as? [Object] ?? [] {
            let state = containerStatus["state"] as? Object ?? [:]
            if let reason = (state["waiting"] as? Object)?["reason"] as? String, !reason.isEmpty {
                return (reason, health(forReason: reason))
            }
            if let terminated = state["terminated"] as? Object, let reason = terminated["reason"] as? String,
               phase != "Succeeded" {
                return (reason, reason == "Completed" ? .neutral : .failed)
            }
        }
        switch phase {
        case "Running": return (phase, ready == total ? .ok : .progressing)
        case "Pending": return (phase, .progressing)
        case "Succeeded": return ("Completed", .neutral)
        case "Failed": return (phase, .failed)
        default: return (phase, .warning)
        }
    }

    static func health(forReason reason: String) -> KubeHealth {
        switch reason {
        case "ContainerCreating", "PodInitializing", "Pending": .progressing
        default: .failed
        }
    }

    static func fillReplicated(_ resource: inout KubeResource, spec: Object, status: Object) {
        let desired = int(spec["replicas"]) ?? 1
        let ready = int(status["readyReplicas"]) ?? 0
        let updated = int(status["updatedReplicas"]) ?? 0
        let available = int(status["availableReplicas"]) ?? 0
        resource.replicas = desired
        resource.status = "\(ready)/\(desired)"
        if desired == 0 {
            resource.health = .neutral
        } else if ready >= desired, updated >= desired {
            resource.health = .ok
        } else {
            resource.health = .progressing
        }
        resource.fields = [KubeField(KubeFieldLabel.ready, "\(ready)/\(desired)"), KubeField(KubeFieldLabel.upToDate, String(updated))]
        if resource.kind == .deployments {
            resource.fields.append(KubeField(KubeFieldLabel.available, String(available)))
        }
        resource.fields.append(KubeField(KubeFieldLabel.images, images(spec)))
    }

    static func fillDaemonSet(_ resource: inout KubeResource, status: Object) {
        let desired = int(status["desiredNumberScheduled"]) ?? 0
        let ready = int(status["numberReady"]) ?? 0
        let updated = int(status["updatedNumberScheduled"]) ?? 0
        let available = int(status["numberAvailable"]) ?? 0
        resource.status = "\(ready)/\(desired)"
        resource.health = desired == 0 ? .neutral : (ready >= desired ? .ok : .progressing)
        resource.fields = [
            KubeField(KubeFieldLabel.desired, String(desired)),
            KubeField(KubeFieldLabel.ready, String(ready)),
            KubeField(KubeFieldLabel.upToDate, String(updated)),
            KubeField(KubeFieldLabel.available, String(available)),
        ]
    }

    static func fillService(_ resource: inout KubeResource, spec: Object, status: Object) {
        let type = spec["type"] as? String ?? "ClusterIP"
        let ports = spec["ports"] as? [Object] ?? []
        resource.ports = ports.compactMap { port in
            guard let number = int(port["port"]) else { return nil }
            return KubePort(port: number, name: port["name"] as? String, proto: port["protocol"] as? String ?? "TCP")
        }
        let portText = ports.compactMap { port -> String? in
            guard let number = int(port["port"]) else { return nil }
            let proto = port["protocol"] as? String ?? "TCP"
            if let nodePort = int(port["nodePort"]) { return "\(number):\(nodePort)/\(proto)" }
            return "\(number)/\(proto)"
        }.joined(separator: ", ")
        let ingress = ((status["loadBalancer"] as? Object)?["ingress"] as? [Object] ?? [])
            .compactMap { ($0["ip"] as? String) ?? ($0["hostname"] as? String) }
        let external = ingress + (spec["externalIPs"] as? [String] ?? [])
        resource.status = type
        resource.health = .neutral
        resource.fields = [
            KubeField(KubeFieldLabel.type, type),
            KubeField(KubeFieldLabel.clusterIP, spec["clusterIP"] as? String ?? "—"),
            KubeField(KubeFieldLabel.externalIP, external.isEmpty ? "—" : external.joined(separator: ", ")),
            KubeField(KubeFieldLabel.ports, portText.isEmpty ? "—" : portText),
        ]
    }

    static func fillIngress(_ resource: inout KubeResource, spec: Object, status: Object) {
        let hosts = (spec["rules"] as? [Object] ?? []).compactMap { $0["host"] as? String }
        let addresses = ((status["loadBalancer"] as? Object)?["ingress"] as? [Object] ?? [])
            .compactMap { ($0["ip"] as? String) ?? ($0["hostname"] as? String) }
        let className = spec["ingressClassName"] as? String ?? "—"
        resource.status = className
        resource.health = .neutral
        resource.fields = [
            KubeField(KubeFieldLabel.ingressClass, className),
            KubeField(KubeFieldLabel.hosts, hosts.isEmpty ? "*" : hosts.joined(separator: ", ")),
            KubeField(KubeFieldLabel.address, addresses.isEmpty ? "—" : addresses.joined(separator: ", ")),
        ]
    }

    static func fillNode(_ resource: inout KubeResource, metadata: Object, spec: Object, status: Object) {
        let conditions = status["conditions"] as? [Object] ?? []
        let ready = conditions.first { $0["type"] as? String == "Ready" }?["status"] as? String == "True"
        var text = ready ? "Ready" : "NotReady"
        if spec["unschedulable"] as? Bool == true { text += ",SchedulingDisabled" }
        let labels = metadata["labels"] as? [String: String] ?? [:]
        let roles = labels.keys
            .filter { $0.hasPrefix("node-role.kubernetes.io/") }
            .map { String($0.dropFirst("node-role.kubernetes.io/".count)) }
            .sorted()
        let addresses = status["addresses"] as? [Object] ?? []
        let internalIP = addresses.first { $0["type"] as? String == "InternalIP" }?["address"] as? String
        resource.status = text
        resource.health = ready ? (text == "Ready" ? .ok : .warning) : .failed
        resource.fields = [
            KubeField(KubeFieldLabel.roles, roles.isEmpty ? "—" : roles.joined(separator: ", ")),
            KubeField(KubeFieldLabel.version, (status["nodeInfo"] as? Object)?["kubeletVersion"] as? String ?? "—"),
            KubeField(KubeFieldLabel.internalIP, internalIP ?? "—"),
        ]
    }

    static func fillEvent(_ resource: inout KubeResource, item: Object) {
        let involved = item["involvedObject"] as? Object ?? [:]
        let type = item["type"] as? String ?? "Normal"
        let object = [involved["kind"] as? String, involved["name"] as? String].compactMap { $0 }.joined(separator: "/")
        resource.status = item["reason"] as? String ?? type
        resource.health = type == "Warning" ? .warning : .neutral
        resource.lastSeen = date(item["lastTimestamp"]) ?? date(item["eventTime"])
            ?? date((item["series"] as? Object)?["lastObservedTime"]) ?? resource.createdAt
        resource.fields = [
            KubeField(KubeFieldLabel.type, type),
            KubeField(KubeFieldLabel.object, object.isEmpty ? "—" : object),
            KubeField(KubeFieldLabel.message, (item["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
            KubeField(KubeFieldLabel.count, String(int(item["count"]) ?? 1)),
        ]
    }

    // MARK: - Helpers

    static func images(_ spec: Object) -> String {
        let template = (spec["template"] as? Object)?["spec"] as? Object ?? [:]
        return (template["containers"] as? [Object] ?? []).compactMap { $0["image"] as? String }.joined(separator: ", ")
    }

    static func keyCount(_ count: Int) -> String {
        String(localized: "\(count) keys", bundle: .module)
    }

    static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) }
    }

    static func date(_ value: Any?) -> Date? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
