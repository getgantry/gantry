import Foundation
import Observation

/// The side effects of a backup run. The live one is ``LiveBackupEnvironment``.
@MainActor
public protocol BackupEnvironment: AnyObject {
    /// A blocking finding about the folder (disk not connected, folder
    /// missing), or nil when the folder can be used.
    func folderProblem(_ folder: String) async -> String?
    /// Writes the archive of the volume to `<folder>/<fileName>`.
    func export(_ schedule: BackupSchedule, fileName: String) async throws
    /// The file names in the folder.
    func listFiles(in folder: String) async throws -> [String]
    /// The size of a file and its first 512 bytes.
    func fileHeader(_ path: String) async throws -> (size: Int64, header: Data)
    func moveFile(_ from: String, to: String) async throws
    func removeFile(_ path: String) async throws
}

/// Runs due backups while Gantry runs. A tick each 60 seconds and one at
/// start; the first tick also runs the backups that Gantry missed.
@MainActor
@Observable
public final class BackupScheduler {
    public let store: BackupScheduleStore
    @ObservationIgnored let environment: any BackupEnvironment
    /// Called after a run fails. The app posts a notification.
    @ObservationIgnored public var onFailure: ((BackupAlert) -> Void)?
    /// The schedules that run now.
    public private(set) var running: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored let calendar: Calendar

    public init(store: BackupScheduleStore, environment: any BackupEnvironment, calendar: Calendar = .current) {
        self.store = store
        self.environment = environment
        self.calendar = calendar
    }

    /// Starts the tick loop. Safe to call more than one time.
    public func start(interval: Duration = .seconds(60)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(now: Date())
                try? await Task.sleep(for: interval)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Runs every due schedule, one after the other.
    public func tick(now: Date) async {
        let due = store.schedules.filter {
            !running.contains($0.id) && BackupSchedulePlan.isDue($0, now: now, calendar: calendar)
        }
        for schedule in due { await run(id: schedule.id, now: now) }
    }

    /// The next run to show for a schedule.
    public func nextRun(of schedule: BackupSchedule, now: Date = Date()) -> Date? {
        BackupSchedulePlan.nextRun(of: schedule, now: now, calendar: calendar)
    }

    /// Runs one schedule now ("Back Up Now" and due runs).
    public func run(id: UUID, now: Date = Date()) async {
        guard let schedule = store.schedule(id: id), running.insert(id).inserted else { return }
        defer { running.remove(id) }
        let fileName = BackupSchedulePlan.fileName(volume: schedule.volume, date: now)
        var updated = schedule
        updated.lastRun = now
        do {
            try await write(schedule, fileName: fileName)
            updated.files.append(fileName)
            updated.lastResult = .succeeded(file: fileName)
            updated.files = await prune(updated)
        } catch {
            let message = BackupSchedulePlan.shortMessage(
                (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            )
            updated.lastResult = .failed(message: message)
            onFailure?(BackupAlert(
                scheduleID: id, hostName: schedule.hostName, volume: schedule.volume, message: message
            ))
        }
        // The user can edit or remove the schedule during the run.
        guard var current = store.schedule(id: id) else { return }
        current.lastRun = updated.lastRun
        current.lastResult = updated.lastResult
        current.files = updated.files
        try? store.upsert(current)
    }

    /// Writes into a hidden partial file, checks it, then gives it the name.
    private func write(_ schedule: BackupSchedule, fileName: String) async throws {
        if let problem = await environment.folderProblem(schedule.folder) { throw OperationFailure(problem) }
        let partial = BackupSchedulePlan.partialName(for: fileName)
        let partialPath = schedule.folder + "/" + partial
        do {
            try await environment.export(schedule, fileName: partial)
            let (size, header) = try await environment.fileHeader(partialPath)
            guard BackupSchedulePlan.looksLikeTar(size: size, header: header) else { throw BackupFailure.notAnArchive }
            try await environment.moveFile(partialPath, to: schedule.folder + "/" + fileName)
        } catch {
            try? await environment.removeFile(partialPath)
            throw error
        }
    }

    /// Deletes the oldest recorded archives above `keep`. Returns the
    /// recorded names that are still in the folder.
    private func prune(_ schedule: BackupSchedule) async -> [String] {
        guard let existing = try? await environment.listFiles(in: schedule.folder) else { return schedule.files }
        let delete = BackupSchedulePlan.filesToDelete(
            existing: existing, recorded: schedule.files, volume: schedule.volume, keep: schedule.keep
        )
        var gone = Set(schedule.files).subtracting(existing)
        for name in delete where (try? await environment.removeFile(schedule.folder + "/" + name)) != nil {
            gone.insert(name)
        }
        return schedule.files.filter { !gone.contains($0) }
    }
}
