import Foundation
import AppCore

/// Labels that depend on the host's engine, so apple/container hosts do not
/// read "Docker".
enum HostKindLabels {
    /// The engine whose version a host reports: "Docker" or "container CLI".
    static func engineName(_ host: DockerHost) -> String {
        host.isAppleContainer ? String(localized: "container CLI") : "Docker"
    }

    /// "Docker 27.1" or "container CLI 1.6.1".
    static func engineVersion(_ host: DockerHost, version: String) -> String {
        "\(engineName(host)) \(version)"
    }
}
