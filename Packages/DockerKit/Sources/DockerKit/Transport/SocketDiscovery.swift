import Foundation

/// Locates a usable local Docker unix socket across common installations
/// (Docker Desktop, OrbStack, Colima, and the system default).
public enum DockerSocketDiscovery {
    /// Returns the first existing socket path, honoring `DOCKER_HOST` first.
    public static func discover(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fileManager = FileManager.default

        if let dockerHost = environment["DOCKER_HOST"], dockerHost.hasPrefix("unix://") {
            let path = String(dockerHost.dropFirst("unix://".count))
            if fileManager.fileExists(atPath: path) {
                return path
            }
        }

        for candidate in allCandidates() where fileManager.fileExists(atPath: candidate) {
            return candidate
        }

        return nil
    }

    /// Ordered list of well-known socket locations (for Settings UI / discovery).
    public static func allCandidates() -> [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.docker/run/docker.sock",
            "\(home)/.orbstack/run/docker.sock",
            "\(home)/.colima/default/docker.sock",
            "/var/run/docker.sock"
        ]
    }
}
