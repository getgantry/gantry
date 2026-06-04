import Foundation

/// Result of `GET /containers/{id}/top` — the container's running processes.
public struct ContainerTop: Hashable, Codable, Sendable {
    /// Column titles, e.g. `["UID", "PID", "PPID", "C", "STIME", "TTY", "TIME", "CMD"]`.
    public var titles: [String]
    /// One row per process, each a list of cells aligned to `titles`.
    public var processes: [[String]]

    enum CodingKeys: String, CodingKey {
        case titles = "Titles"
        case processes = "Processes"
    }

    public init(titles: [String] = [], processes: [[String]] = []) {
        self.titles = titles
        self.processes = processes
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        titles = try c.decodeIfPresent([String].self, forKey: .titles) ?? []
        // Docker emits null for Processes when none are running.
        processes = try c.decodeIfPresent([[String]].self, forKey: .processes) ?? []
    }
}
