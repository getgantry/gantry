import Foundation
import Observation

/// Top-level app state: the set of host sessions, backed by a persisted host list.
@MainActor
@Observable
public final class AppModel {
    public private(set) var sessions: [HostSession]

    public init() {
        let hosts = Self.loadHosts()
        sessions = hosts.map(HostSession.init)
    }

    public func session(id: UUID) -> HostSession? {
        sessions.first { $0.id == id }
    }

    public func addHost(_ host: DockerHost) {
        sessions.append(HostSession(host: host))
        persist()
    }

    public func removeHost(id: UUID) {
        sessions.removeAll { $0.id == id }
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        let hosts = sessions.map(\.host)
        Self.saveHosts(hosts)
    }

    /// Loads the persisted host list, seeding a default Local host on first run.
    private static func loadHosts() -> [DockerHost] {
        let url = hostsFileURL()

        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let hosts = try? decoder.decode([DockerHost].self, from: data), !hosts.isEmpty {
                return hosts
            }
        }

        let defaults = [DockerHost(name: "Local", kind: .local)]
        saveHosts(defaults)
        return defaults
    }

    private static func saveHosts(_ hosts: [DockerHost]) {
        guard let url = hostsFileURL() else {
            print("AppModel: cannot resolve hosts.json location")
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(hosts)
            try data.write(to: url, options: .atomic)
        } catch {
            print("AppModel: failed to persist hosts: \(error.localizedDescription)")
        }
    }

    private static func hostsFileURL() -> URL? {
        guard let appSupport = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) else {
            return nil
        }
        return appSupport
            .appendingPathComponent("Gantry", isDirectory: true)
            .appendingPathComponent("hosts.json", isDirectory: false)
    }
}
