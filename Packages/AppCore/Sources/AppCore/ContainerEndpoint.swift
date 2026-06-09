import Foundation
import DockerKit

/// A directly-reachable network endpoint for a running container, resolved from
/// the host kind, published ports, and — for apple/container — the routable IP
/// and DNS hostname. Drives the tray menu and address views: "open in browser"
/// and "copy host:port".
public struct ContainerEndpoint: Sendable, Hashable {
    /// The host portion used to reach the service: a DNS name, an IP, or
    /// "localhost".
    public var host: String
    /// The port to reach it on.
    public var port: Int
    /// True when `host` is a resolvable local DNS name (apple/container domain).
    public var isDNSName: Bool

    public init(host: String, port: Int, isDNSName: Bool) {
        self.host = host
        self.port = port
        self.isDNSName = isDNSName
    }

    /// The copyable `host:port` string, e.g. `web.test:8080` or `127.0.0.1:5432`.
    public var hostPort: String { "\(host):\(port)" }

    /// The browser URL for the endpoint.
    public var url: URL? { URL(string: "http://\(host):\(port)") }
}

extension HostSession {
    /// Label Gantry stamps at create time recording the `--dns-domain` used, so
    /// the resolvable hostname can be reconstructed reliably later.
    public static let dnsDomainLabelKey = "com.gantry.dns-domain"

    /// The resolvable DNS hostname for a container when it was launched on a
    /// local apple/container domain (e.g. `web.test`). Nil for other hosts or
    /// when no domain is recorded.
    public func dnsHostname(for container: ContainerSummary) -> String? {
        guard host.isAppleContainer else { return nil }
        let domain = container.labels[Self.dnsDomainLabelKey]
            ?? cachedDetails(for: container.id)?.config.domainname
        guard let domain, !domain.isEmpty else { return nil }
        return "\(container.displayName).\(domain)"
    }

    /// The routable container IP (apple/container), from cached inspect data.
    public func containerIP(for container: ContainerSummary) -> String? {
        let value = cachedDetails(for: container.id)?
            .networkSettings.ipAddress?.trimmingCharacters(in: .whitespaces)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Every exposed container port we can infer from the summary plus any
    /// cached inspect data, de-duplicated and sorted ascending.
    public func exposedPorts(for container: ContainerSummary) -> [Int] {
        var set = Set<Int>()
        for port in container.ports { set.insert(port.privatePort) }
        if let ports = cachedDetails(for: container.id)?.networkSettings.ports {
            for key in ports.keys {
                if let n = Int(key.split(separator: "/").first.map(String.init) ?? "") {
                    set.insert(n)
                }
            }
        }
        return set.sorted()
    }

    /// The best directly-reachable endpoint for a container, when one exists
    /// without a tunnel. Prefers a DNS name, then the routable IP (apple), then
    /// a published port on localhost (local Docker). SSH hosts return nil — their
    /// ports require a forward, which the detail view's Ports section sets up.
    public func primaryEndpoint(for container: ContainerSummary) -> ContainerEndpoint? {
        if host.isAppleContainer {
            // apple/container is reachable on the container's own ports via its
            // routable IP — no publishing needed. Prefer the IP for the openable
            // endpoint: it always resolves, whereas a `name.domain` only resolves
            // once a default DNS domain is configured system-wide (the DNS name
            // is still offered separately via `dnsHostname`).
            guard let port = exposedPorts(for: container).first else { return nil }
            if let ip = containerIP(for: container) {
                return ContainerEndpoint(host: ip, port: port, isDNSName: false)
            }
            if let name = dnsHostname(for: container) {
                return ContainerEndpoint(host: name, port: port, isDNSName: true)
            }
            return nil
        }
        // Local Docker: a published port opens directly on localhost (or its
        // concrete bind address).
        let candidates = container.ports
            .filter { ($0.publicPort ?? 0) > 0 }
            .sorted { ($0.publicPort ?? 0) < ($1.publicPort ?? 0) }
        for port in candidates {
            if let url = directBrowserURL(for: port), let p = url.port {
                return ContainerEndpoint(host: url.host ?? "localhost", port: p, isDNSName: false)
            }
        }
        return nil
    }
}
