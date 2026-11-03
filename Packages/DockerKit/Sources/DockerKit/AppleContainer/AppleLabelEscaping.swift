import Foundation

/// `container create` rejects a label whose value contains `=` (CLI 1.6.1), so
/// such values are percent-escaped. Unescaping happens only on containers that
/// carry `markerKey`: a value set outside Gantry may legitimately hold `%3D`.
/// Volume, network and build labels keep `=` fine and are never escaped.
enum AppleLabelEscaping {
    static let markerKey = "com.gantry.label-escaping"
    static let markerValue = "percent"

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: "=", with: "%3D")
    }

    static func unescape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "%3D", with: "=")
            .replacingOccurrences(of: "%25", with: "%")
    }

    /// Escapes only when some value needs it, so most labels stay readable in
    /// `container inspect`. A stale marker in the input is recomputed.
    static func encodeForCreate(_ labels: [String: String]) -> [String: String] {
        var labels = labels
        labels.removeValue(forKey: markerKey)
        guard labels.values.contains(where: { $0.contains("=") }) else { return labels }
        var escaped = labels.mapValues(escape)
        escaped[markerKey] = markerValue
        return escaped
    }

    /// Drops the marker so a recreate does not copy it.
    static func decodeContainerLabels(_ labels: [String: String]) -> [String: String] {
        guard labels[markerKey] == markerValue else { return labels }
        var labels = labels
        labels.removeValue(forKey: markerKey)
        return labels.mapValues(unescape)
    }
}
