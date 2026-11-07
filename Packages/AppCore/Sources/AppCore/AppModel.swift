import Foundation
import Observation
import os

/// Top-level app state: the set of host sessions, backed by a persisted host list.
@MainActor
@Observable
public final class AppModel {
    private static let log = Logger(subsystem: "com.andrewkomkov.Gantry", category: "AppModel")
    public private(set) var sessions: [HostSession] {
        didSet { for session in sessions { session.operations = operations } }
    }

    /// Long operations of every host, for the activity button.
    public let operations = OperationCenter()

    /// The Kubernetes section; it is not bound to a host.
    public let kubernetes = KubernetesBrowser()

    /// Receives notable container events (crash/OOM/unhealthy) from every
    /// session. The app layer sets this to post system notifications. Assigning
    /// it wires the handler into all existing sessions; new sessions inherit it.
    @ObservationIgnored
    public var containerAlertHandler: ((ContainerAlert) -> Void)? {
        didSet {
            for session in sessions {
                session.onContainerAlert = containerAlertHandler
            }
        }
    }

    /// How the model looks for Docker and the apple CLI (a seam for tests).
    @ObservationIgnored private let detection: LocalDockerDetection
    /// Where the Local-host choice is stored.
    @ObservationIgnored private let defaults: UserDefaults

    public init(detection: LocalDockerDetection = .live, defaults: UserDefaults = .standard) {
        self.detection = detection
        self.defaults = defaults
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--gantry-test-in-memory-containers") {
            let host = DockerHost(name: "Gantry Fixture Host", kind: .local)
            let session = HostSession(host: host)
            session.installWindowRouteFixtureContainers()
            sessions = [session]
            return
        }
#endif
        let hosts = Self.loadHosts(detection: detection, defaults: defaults)
        sessions = hosts.map(HostSession.init)
        for session in sessions { session.operations = operations }
        applyLocalDockerPolicy()
    }

    // MARK: - Local Docker host

    /// What the user did with the built-in Local host (see ``LocalDockerPolicy``).
    public var localDockerChoice: LocalDockerPolicy.Choice {
        get {
            defaults.string(forKey: LocalDockerPolicy.choiceKey)
                .flatMap(LocalDockerPolicy.Choice.init(rawValue:)) ?? .automatic
        }
        set { defaults.set(newValue.rawValue, forKey: LocalDockerPolicy.choiceKey) }
    }

    /// Hides the default Local host when Docker is missing and apple/container
    /// is present, and restores it when Docker appears later. Call it at launch
    /// and when the app becomes active. Explicit user choices always win.
    public func applyLocalDockerPolicy() {
        let choice = localDockerChoice
        let action = LocalDockerPolicy.action(
            hosts: sessions.map(\.host),
            choice: choice,
            socketFound: detection.socketFound(),
            appleCLIFound: detection.appleCLIFound()
        )
        switch action {
        case .none:
            return
        case .hide(let id):
            sessions.removeAll { $0.id == id }
        case .restore:
            let session = HostSession(host: DockerHost(name: LocalDockerPolicy.defaultName, kind: .local))
            session.onContainerAlert = containerAlertHandler
            sessions.insert(session, at: 0)
        }
        localDockerChoice = LocalDockerPolicy.choice(after: action, from: choice)
        persist()
    }

    public func session(id: UUID) -> HostSession? {
        sessions.first { $0.id == id }
    }

    public func addHost(_ host: DockerHost) {
        let session = HostSession(host: host)
        session.onContainerAlert = containerAlertHandler
        sessions.append(session)
        // Adding a Local Docker host is an explicit choice: never auto-hide it.
        if host.isLocal { localDockerChoice = .added }
        persist()
    }

    public func removeHost(id: UUID) {
        // Removing the Local host is an explicit choice: never add it back.
        if session(id: id)?.host.isLocal == true { localDockerChoice = .removed }
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
                replacement.onContainerAlert = containerAlertHandler
                sessions[index] = replacement
                result = replacement
            }
        } else {
            // Connection-relevant change: replace the session so the new host
            // takes effect on the next connect(). The caller reconnects.
            let replacement = HostSession(host: host)
            replacement.onContainerAlert = containerAlertHandler
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

    /// Loads the persisted host list. On first run it seeds the hosts that
    /// fit this Mac: Local Docker when a socket exists, apple/container when
    /// its CLI exists (see ``LocalDockerPolicy/seedHosts(socketFound:appleCLIFound:)``).
    private static func loadHosts(detection: LocalDockerDetection, defaults: UserDefaults) -> [DockerHost] {
        let url = HostsStore.fileURL()

        if let url, let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            if let hosts = try? decoder.decode([DockerHost].self, from: data), !hosts.isEmpty {
                return hosts
            }
        }

        let seed = LocalDockerPolicy.seedHosts(
            socketFound: detection.socketFound(),
            appleCLIFound: detection.appleCLIFound()
        )
        defaults.set(seed.choice.rawValue, forKey: LocalDockerPolicy.choiceKey)
        saveHosts(seed.hosts)
        return seed.hosts
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
