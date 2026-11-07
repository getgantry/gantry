import Foundation

/// A `gantry://` link that opens a place in the app. Scripts, Shortcuts and
/// tests use it to drive the window without clicks:
///
///     gantry://open/containers?host=Apple%20Container&item=web
///     gantry://open/kubernetes        gantry://palette        gantry://settings
public enum AppLink: Equatable, Sendable {
    /// A top-level place: `dashboard`, `kubernetes`, or a host section name.
    case open(target: String, host: String?, item: String?)
    case palette
    case settings
    /// Debug builds only: write a PNG of the main window to an absolute path.
    case snapshot(path: String)
    /// Debug builds only: write the window state (selection, sheets) as JSON.
    case state(path: String)
    /// Debug builds only: `light`, `dark` or `system`.
    case appearance(String)

    /// Targets that do not belong to a host.
    public static let globalTargets: Set<String> = ["dashboard", "kubernetes"]
    /// Host section names, the same as `HostSection.rawValue` in the app.
    public static let sectionTargets: Set<String> = [
        "overview", "containers", "images", "volumes", "networks",
        "machines", "clusters", "hostFiles", "system",
    ]

    /// Parses a `gantry://` URL. Returns nil for other URLs, for the
    /// `gantry://control` links of the widget extension, and for unknown places.
    public static func parse(_ url: URL, scheme: String = "gantry") -> AppLink? {
        guard url.scheme == scheme, let kind = url.host(percentEncoded: false) else { return nil }
        let query = Dictionary(
            (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
                .compactMap { item in item.value.map { (item.name, $0) } },
            uniquingKeysWith: { first, _ in first }
        )
        let path = url.pathComponents.filter { $0 != "/" }
        switch kind {
        case "open":
            guard let target = path.first.map(canonicalTarget),
                  globalTargets.contains(target) || sectionTargets.contains(target) else { return nil }
            return .open(target: target, host: nonEmpty(query["host"]), item: nonEmpty(query["item"]))
        case "palette":
            return .palette
        case "settings":
            return .settings
        case "debug":
            switch path.first {
            case "snapshot":
                guard let file = query["path"], file.hasPrefix("/") else { return nil }
                return .snapshot(path: file)
            case "state":
                guard let file = query["path"], file.hasPrefix("/") else { return nil }
                return .state(path: file)
            case "appearance":
                guard let mode = query["mode"], ["light", "dark", "system"].contains(mode) else { return nil }
                return .appearance(mode)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    /// Accepts any letter case and `files` / `host-files` for `hostFiles`.
    static func canonicalTarget(_ raw: String) -> String {
        switch raw.lowercased() {
        case "files", "host-files", "hostfiles": "hostFiles"
        default: raw.lowercased()
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Picks the host for a link: by id, then by name (any case). Without a
    /// name, the only host or the first one in the list.
    public static func resolveHost(_ wanted: String?, in hosts: [(id: UUID, name: String)]) -> UUID? {
        guard let wanted else { return hosts.first?.id }
        if let id = UUID(uuidString: wanted), hosts.contains(where: { $0.id == id }) { return id }
        return hosts.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }?.id
    }
}

/// Holds links that arrive before the main window is ready (cold launch).
@MainActor
public enum PendingAppLinks {
    private static var links: [AppLink] = []
    public static func add(_ link: AppLink) { links.append(link) }
    public static func drain() -> [AppLink] {
        defer { links.removeAll() }
        return links
    }
}
