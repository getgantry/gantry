import Foundation
import Observation

/// Stores backup schedules in `~/Library/Application Support/Gantry/backup-schedules.json`,
/// next to the other settings files of Gantry.
@MainActor
@Observable
public final class BackupScheduleStore {
    public private(set) var schedules: [BackupSchedule] = []
    @ObservationIgnored let fileURL: URL?

    public static let shared = BackupScheduleStore(fileURL: BackupScheduleStore.defaultFileURL)

    /// `GANTRY_BACKUPS_PATH` replaces the path, so a Debug build under test
    /// does not touch the real schedules.
    public static var defaultFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["GANTRY_BACKUPS_PATH"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Gantry/backup-schedules.json")
    }

    /// `fileURL` nil keeps the store in memory (tests).
    public init(fileURL: URL?) {
        self.fileURL = fileURL
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            schedules = (try? Self.decoder.decode([BackupSchedule].self, from: data)) ?? []
        }
    }

    public func schedule(id: UUID) -> BackupSchedule? {
        schedules.first { $0.id == id }
    }

    public func schedules(hostID: UUID, volume: String) -> [BackupSchedule] {
        schedules.filter { $0.hostID == hostID && $0.volume == volume }
    }

    /// Adds a new schedule or replaces the one with the same id.
    public func upsert(_ schedule: BackupSchedule) throws {
        if let index = schedules.firstIndex(where: { $0.id == schedule.id }) {
            schedules[index] = schedule
        } else {
            schedules.append(schedule)
        }
        try save()
    }

    /// Forgets a schedule. Its archives stay in the folder.
    public func remove(id: UUID) throws {
        schedules.removeAll { $0.id == id }
        try save()
    }

    private func save() throws {
        guard let fileURL else { return }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(schedules).write(to: fileURL, options: .atomic)
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
