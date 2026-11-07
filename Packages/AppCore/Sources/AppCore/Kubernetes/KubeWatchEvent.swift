import Foundation

/// One line of a watch stream (`{"type":"ADDED","object":{…}}`).
public enum KubeWatchEvent: Equatable, Sendable {
    public enum Change: String, Sendable {
        case added = "ADDED"
        case modified = "MODIFIED"
        case deleted = "DELETED"
    }

    case changed(Change, KubeResource, resourceVersion: String?)
    case bookmark(String)
    /// The resourceVersion is too old (410 Gone): list again.
    case expired
    case ignored

    public static func parse(_ line: String, kind: KubeResourceKind) -> KubeWatchEvent {
        guard let root = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = root["type"] as? String,
              let object = root["object"] as? [String: Any] else { return .ignored }
        let version = (object["metadata"] as? [String: Any])?["resourceVersion"] as? String
        switch type {
        case "BOOKMARK":
            return version.map(KubeWatchEvent.bookmark) ?? .ignored
        case "ERROR":
            // Any error status ends this watch; a new list is always safe.
            return .expired
        default:
            guard let change = Change(rawValue: type) else { return .ignored }
            return .changed(change, KubeResourceParser.resource(from: object, kind: kind), resourceVersion: version)
        }
    }

    /// `metadata.resourceVersion` of a list response.
    public static func listResourceVersion(_ data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ((root["metadata"] as? [String: Any])?["resourceVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The list order of the API: namespace, then name. Events come newest first.
    public static func sorted(_ resources: [KubeResource], kind: KubeResourceKind) -> [KubeResource] {
        if kind == .events {
            return resources.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }
        }
        return resources.sorted { ($0.namespace ?? "", $0.name) < ($1.namespace ?? "", $1.name) }
    }
}
