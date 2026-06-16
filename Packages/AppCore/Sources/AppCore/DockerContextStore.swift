import Foundation

/// Reads the Docker CLI's saved contexts (`docker context ls`) from
/// `~/.docker/contexts/meta/*/meta.json`, so an `ssh://` context the user
/// already created in the terminal can be imported as a Gantry host.
public enum DockerContextStore {
    /// One saved context: its name and the raw daemon host URL.
    public struct Entry: Sendable, Equatable, Hashable {
        public var name: String
        public var host: String
        public init(name: String, host: String) {
            self.name = name
            self.host = host
        }
    }

    /// A parsed context endpoint.
    public enum Endpoint: Sendable, Equatable {
        case ssh(host: String, port: Int, user: String)
        case unixSocket(String)
        case unsupported(String)
    }

    /// All saved contexts that carry a daemon host, sorted by name. The implicit
    /// `default` context (the local env) is omitted.
    public static func list(contextsDirectory: URL? = nil) -> [Entry] {
        let base = contextsDirectory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".docker/contexts/meta", isDirectory: true)
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: nil
        ) else { return [] }

        var entries: [Entry] = []
        for dir in dirs {
            let metaURL = dir.appendingPathComponent("meta.json")
            guard let data = try? Data(contentsOf: metaURL),
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let name = root["Name"] as? String, name != "default",
                  let host = dockerHost(in: root), !host.isEmpty
            else { continue }
            entries.append(Entry(name: name, host: host))
        }
        return entries.sorted { $0.name < $1.name }
    }

    private static func dockerHost(in root: [String: Any]) -> String? {
        let endpoints = root["Endpoints"] as? [String: Any]
        let docker = endpoints?["docker"] as? [String: Any]
        return docker?["Host"] as? String
    }

    /// Parses a context's daemon host URL into something Gantry can use.
    public static func endpoint(for host: String) -> Endpoint {
        if host.hasPrefix("ssh://") {
            guard let comps = URLComponents(string: host), let h = comps.host, !h.isEmpty else {
                return .unsupported(host)
            }
            return .ssh(host: h, port: comps.port ?? 22, user: comps.user ?? "")
        }
        if host.hasPrefix("unix://") {
            return .unixSocket(String(host.dropFirst("unix://".count)))
        }
        return .unsupported(host)
    }
}
