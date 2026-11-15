import Foundation
import Observation
import DockerKit

/// Reads and writes the stored build records.
public protocol BuildHistoryPersistence: Sendable {
    func load() -> [BuildRecord]
    func save(_ records: [BuildRecord]) throws
}

/// `~/Library/Application Support/Gantry/build-history.json`, owner-only.
public struct BuildHistoryFile: BuildHistoryPersistence {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// The default file. `GANTRY_BUILD_HISTORY_PATH` replaces it (tests).
    public static var defaultURL: URL {
        if let override = ProcessInfo.processInfo.environment["GANTRY_BUILD_HISTORY_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gantry/build-history.json")
    }

    public func load() -> [BuildRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([BuildRecord].self, from: data)) ?? []
    }

    public func save(_ records: [BuildRecord]) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: [.atomic])
        // Logs can hold private build output.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The builds that Gantry started, per host. Buildx records are not stored.
@MainActor
@Observable
public final class BuildHistoryStore {
    public static let maxRecordsPerHost = 100

    public private(set) var records: [BuildRecord] = []
    @ObservationIgnored private let persistence: BuildHistoryPersistence?
    @ObservationIgnored private var lastSave: Task<Void, Never>?

    /// The store at the default file.
    public static func live() -> BuildHistoryStore {
        BuildHistoryStore(persistence: BuildHistoryFile(url: BuildHistoryFile.defaultURL))
    }

    /// `persistence` nil keeps the records in memory.
    public init(persistence: BuildHistoryPersistence?) {
        self.persistence = persistence
        var loaded = persistence?.load() ?? []
        var changed = false
        for index in loaded.indices where loaded[index].status == .running {
            loaded[index].status = .interrupted
            changed = true
        }
        records = loaded
        if changed { save() }
    }

    /// The records of one host, newest first.
    public func records(for hostID: UUID) -> [BuildRecord] {
        records.filter { $0.hostID == hostID }.sorted { $0.startedAt > $1.startedAt }
    }

    public func record(id: String) -> BuildRecord? {
        records.first { $0.id == id }
    }

    /// Records a build that starts now and returns its ID.
    @discardableResult
    public func begin(_ spec: ImageBuildSpec, hostID: UUID, at date: Date = Date()) -> String {
        let record = BuildRecord(starting: spec, hostID: hostID, at: date)
        records.append(record)
        trim(hostID: hostID)
        save()
        return record.id
    }

    public func finish(
        id: String, status: BuildStatus, log: String, imageID: String? = nil,
        errorMessage: String? = nil, at date: Date = Date()
    ) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].finish(status: status, log: log, imageID: imageID, errorMessage: errorMessage, at: date)
        save()
    }

    /// Removes the Gantry records of one host.
    public func clear(hostID: UUID) {
        records.removeAll { $0.hostID == hostID }
        save()
    }

    /// Removes the records of a removed host.
    public func removeHost(_ hostID: UUID) {
        guard records.contains(where: { $0.hostID == hostID }) else { return }
        clear(hostID: hostID)
    }

    /// Waits until the last change is on disk.
    public func flush() async {
        await lastSave?.value
    }

    private func trim(hostID: UUID) {
        let own = records(for: hostID)
        guard own.count > Self.maxRecordsPerHost else { return }
        let removed = Set(own.dropFirst(Self.maxRecordsPerHost).map(\.id))
        records.removeAll { removed.contains($0.id) }
    }

    /// Writes off the main actor, in order.
    private func save() {
        guard let persistence else { return }
        let snapshot = records
        let previous = lastSave
        lastSave = Task.detached(priority: .utility) {
            await previous?.value
            try? persistence.save(snapshot)
        }
    }
}
