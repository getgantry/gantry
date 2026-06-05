import Foundation
import Observation
import os

/// Top-level app state: the set of host sessions, backed by a persisted host list.
@MainActor
@Observable
public final class AppModel {
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "AppModel")
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

    /// Moves a host up or down in the sidebar order, persisting the new order.
    public func moveHost(id: UUID, by offset: Int) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard sessions.indices.contains(target) else { return }
        sessions.swapAt(index, target)
        persist()
    }

    /// Applies an edited `DockerHost`, persisting the change and keeping the
    /// session list as the single source of truth for the sidebar.
    ///
    /// `HostSession.host` is a `let`, so a host whose connection-relevant fields
    /// changed cannot be mutated in place. In that case we replace the session
    /// instance at the same index (preserving sidebar order) with a fresh,
    /// disconnected one. Callers are responsible for tearing down the old
    /// session and reconnecting the new one — `updateHost` does not touch the
    /// network. When only cosmetic fields changed (currently just `name`) the
    /// existing session is left in place to avoid dropping a live connection.
    ///
    /// Returns the session that now backs `host.id` (either the preserved one
    /// or the freshly created replacement), or nil if no session had that id.
    @discardableResult
    public func updateHost(_ host: DockerHost) -> HostSession? {
        guard let index = sessions.firstIndex(where: { $0.id == host.id }) else {
            return nil
        }

        let existing = sessions[index]
        let result: HostSession
        if Self.isConnectionEquivalent(existing.host, host) {
            // Only display-level fields changed; mutate the persisted copy by
            // swapping in a new session only if the stored host actually differs.
            if existing.host == host {
                result = existing
            } else {
                let replacement = HostSession(host: host)
                sessions[index] = replacement
                result = replacement
            }
        } else {
            // Connection-relevant change: replace the session so the new host
            // takes effect on the next connect(). The caller reconnects.
            let replacement = HostSession(host: host)
            sessions[index] = replacement
            result = replacement
        }

        persist()
        return result
    }

    /// Whether two hosts would dial the exact same daemon with the same
    /// credentials, i.e. nothing connection-relevant changed (only `name`).
    private static func isConnectionEquivalent(_ lhs: DockerHost, _ rhs: DockerHost) -> Bool {
        lhs.kind == rhs.kind && lhs.socketPathOverride == rhs.socketPathOverride
    }

    // MARK: - Persistence

    private func persist() {
        let hosts = sessions.map(\.host)
        Self.saveHosts(hosts)
    }

    /// Loads the persisted host list, seeding a default Local host on first run.
    private static func loadHosts() -> [DockerHost] {
        let url = HostsStore.fileURL()

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
        guard let url = HostsStore.fileURL() else {
            log.error("cannot resolve hosts.json location")
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
            log.error("failed to persist hosts: \(error.localizedDescription, privacy: .public)")
        }
    }
}
